require 'net/http'

module Comfyui
  # Thin wrapper around the ComfyUI HTTP API for one backend.
  class Client
    CLIENT_ID = 'comfier-ui'.freeze
    DOWNLOADER_NODE = 'ComfierModelDownload'.freeze
    NETWORK_ERRORS = [
      Timeout::Error, SocketError, SystemCallError, EOFError, IOError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
    ].freeze

    attr_reader :backend

    def initialize(backend, open_timeout: 5, read_timeout: 30)
      @backend = backend
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def system_stats = get_json('system_stats')

    # Number of prompts running or waiting on this server.
    def queue_depth
      queue = get_json('queue')
      Array(queue['queue_running']).size + Array(queue['queue_pending']).size
    end

    # Queues an API-format workflow graph and returns ComfyUI's prompt id.
    def submit(graph)
      body = parse_json(perform(json_request(Net::HTTP::Post, 'prompt', { prompt: graph, client_id: CLIENT_ID })))
      body.fetch('prompt_id') { raise Error, 'ComfyUI accepted the workflow but returned no prompt id' }
    end

    def result(prompt_id)
      Result.new(get_json("history/#{ERB::Util.url_encode(prompt_id)}")[prompt_id])
    end

    # Fetches an output file described by a history entry ({ filename, subfolder, type }).
    def download(file)
      query = { filename: file.fetch('filename'), subfolder: file.fetch('subfolder', ''),
                type: file.fetch('type', 'output') }
      perform(Net::HTTP::Get.new(uri('view', query))).body
    end

    # Uploads an input image and returns the name workflows should reference it by.
    def upload_image(io, filename:, content_type:)
      request = Net::HTTP::Post.new(uri('upload/image'))
      request.set_form([['image', io, { filename:, content_type: }], %w[overwrite true]], 'multipart/form-data')
      body = parse_json(perform(request))
      [body['subfolder'].presence, body.fetch('name')].compact.join('/')
    end

    # Files in one models folder, as loader nodes name them ("sub/model.safetensors").
    # A folder the server doesn't know about has no files.
    def model_files(directory)
      Array(get_json("models/#{ERB::Util.url_encode(directory)}")).map { it.to_s.tr('\\', '/') }
    rescue NotFound
      []
    end

    def downloader_node?
      get_json("object_info/#{DOWNLOADER_NODE}").key?(DOWNLOADER_NODE)
    rescue NotFound
      false
    end

    include ManagerEndpoints

    private

    def get_json(path, query = nil) = parse_json(perform(Net::HTTP::Get.new(uri(path, query))))

    def json_request(klass, path, payload)
      klass.new(uri(path), 'Content-Type' => 'application/json').tap { it.body = payload.to_json }
    end

    def uri(path, query = nil)
      URI("#{backend.base_url}/#{path}").tap { it.query = URI.encode_www_form(query) if query }
    end

    def perform(request)
      request['Authorization'] = "Bearer #{backend.auth_token}" if backend.auth_token.present?
      response = http_for(request.uri).request(request)
      return response if response.is_a?(Net::HTTPSuccess)

      raise error_for(response)
    rescue *NETWORK_ERRORS => e
      raise ConnectionError, "Couldn't reach #{backend.name}: #{e.message}"
    end

    def http_for(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |http|
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
      end
    end

    def parse_json(response)
      JSON.parse(response.body.presence || '{}')
    rescue JSON::ParserError
      raise Error, "#{backend.name} returned something that isn't JSON — is the URL pointing at ComfyUI?"
    end

    def error_for(response)
      case response.code.to_i
      when 400 then PromptRejected.new(rejection_message(response.body))
      when 401, 403
        Forbidden.new("#{backend.name} refused the request (HTTP #{response.code}); check the auth token")
      when 404 then NotFound.new("#{backend.name} returned HTTP 404 for #{response.uri&.path || 'that request'}")
      else Error.new("#{backend.name} returned HTTP #{response.code}")
      end
    end

    # Turns ComfyUI's validation response into something a person can act on.
    def rejection_message(body)
      data = JSON.parse(body.to_s)
      error = data['error'].is_a?(Hash) ? data['error'] : { 'message' => data['error'].to_s }
      node_errors = (data['node_errors'] || {}).flat_map do |_id, node|
        Array(node['errors']).map do |error|
          "#{node['class_type']}: #{[error['message'], error['details']].compact_blank.join(' — ')}"
        end
      end
      [error['message'].presence || 'ComfyUI rejected the workflow', *node_errors].join('. ')
    rescue JSON::ParserError
      'ComfyUI rejected the workflow'
    end
  end
end

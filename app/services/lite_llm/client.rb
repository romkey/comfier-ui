require 'net/http'
require 'json'

module LiteLlm
  # OpenAI-compatible chat client for a LiteLLM proxy.
  class Client
    NETWORK_ERRORS = [
      Timeout::Error, SocketError, SystemCallError, EOFError, IOError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
    ].freeze

    def self.configured?
      url.present? && model.present?
    end

    def self.missing_config_keys
      %w[LITELLM_URL LITELLM_MODEL].select { |key| ENV.fetch(key, '').strip.empty? }
    end

    def self.url = ENV.fetch('LITELLM_URL', nil)&.strip&.chomp('/')

    def self.model = ENV.fetch('LITELLM_MODEL', nil)&.strip

    def self.api_key = ENV.fetch('LITELLM_API_KEY', nil)&.strip

    def self.timeout_seconds
      ENV.fetch('LITELLM_TIMEOUT_SECONDS', 180).to_i
    end

    def self.chat(system:, user:) = new.chat(system:, user:)

    def chat(system:, user:)
      raise Error, 'LiteLLM is not configured (set LITELLM_URL and LITELLM_MODEL in .env)' unless self.class.configured?

      body = {
        model: self.class.model,
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user }
        ],
        response_format: { type: 'json_object' }
      }
      response = post_json(completions_url, body)
      content = response.dig('choices', 0, 'message', 'content')
      raise Error, 'LiteLLM returned an empty reply' if content.blank?

      content
    end

    private

    def completions_url
      URI("#{self.class.url}/v1/chat/completions")
    end

    def post_json(uri, payload)
      response = http(uri).request(build_request(uri, payload))
      raise Error, "LiteLLM returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, 'LiteLLM returned something that isn\'t JSON'
    rescue *NETWORK_ERRORS => e
      raise Error, "Couldn't reach LiteLLM: #{e.message}"
    end

    def build_request(uri, payload)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Authorization'] = "Bearer #{self.class.api_key}" if self.class.api_key.present?
      request.body = JSON.generate(payload)
      request
    end

    def http(uri)
      Net::HTTP.start(uri.host, uri.port,
                      use_ssl: uri.scheme == 'https', open_timeout: 5,
                      read_timeout: self.class.timeout_seconds)
    end
  end
end

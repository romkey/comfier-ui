require 'net/http'

# Sends a generation notification to its owner as a Slack direct message from the Comfier bot.
# The bot token needs the chat:write, im:write and files:write scopes.
class SlackNotifier
  class Error < StandardError; end

  API_URL = 'https://slack.com/api/'.freeze
  NETWORK_ERRORS = [
    Timeout::Error, SocketError, SystemCallError, EOFError, IOError,
    OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
  ].freeze

  def self.configured? = token.present?

  def self.token = ENV.fetch('SLACK_BOT_TOKEN', nil)

  def self.call(generation) = new(generation).call

  def initialize(generation)
    @notification = GenerationNotification.new(generation)
    @user = generation.user
  end

  def call
    channel = api('conversations.open', users: @user.slack_uid).dig('channel', 'id')
    files = @notification.attachable_files
    return api('chat.postMessage', channel:, text: message) if files.empty?

    uploaded = files.map { |output| upload(output) }
    api('files.completeUploadExternal', channel_id: channel, initial_comment: message, files: uploaded.to_json)
  end

  private

  def message
    lines = ["*#{escape(@notification.headline)}*", escape(@notification.title)]
    lines << escape(@notification.error_message) if @notification.error_message
    lines << 'Too large to attach. Open it in Comfier.' if @notification.files_left_out?
    lines << "<#{@notification.url}|Open in Comfier>"
    lines.join("\n")
  end

  def escape(text) = text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')

  def upload(output)
    data = output.download
    filename = output.filename.to_s
    target = api('files.getUploadURLExternal', filename:, length: data.bytesize)
    post(URI(target.fetch('upload_url')), data, 'application/octet-stream')
    { id: target.fetch('file_id'), title: filename }
  end

  def api(method, **params)
    response = post(URI.join(API_URL, method), URI.encode_www_form(params), 'application/x-www-form-urlencoded',
                    authorize: true)
    body = JSON.parse(response.body)
    raise Error, "Slack #{method} failed: #{body['error'] || 'unknown error'}" unless body['ok']

    body
  rescue JSON::ParserError
    raise Error, "Slack #{method} returned something that isn't JSON"
  end

  def post(uri, body, content_type, authorize: false)
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = content_type
    request['Authorization'] = "Bearer #{self.class.token}" if authorize
    request.body = body
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5,
                                                   read_timeout: 60) { |http| http.request(request) }
    raise Error, "Slack returned HTTP #{response.code} for #{uri.path}" unless response.is_a?(Net::HTTPSuccess)

    response
  rescue *NETWORK_ERRORS => e
    raise Error, "Couldn't reach Slack: #{e.message}"
  end
end

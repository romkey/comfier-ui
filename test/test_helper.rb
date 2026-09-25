ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'

# DATABASE_URL overrides database.yml, so running tests inside the dev container would load fixtures into the
# development database. This has to run before rails/test_help, which touches the schema.
test_database = ActiveRecord::Base.connection_db_config.database.to_s
unless test_database.end_with?('_test')
  abort "Refusing to run tests against #{test_database.inspect}. Use " \
        '`docker compose -f docker-compose.test.yml run --rm test`, or point DATABASE_URL at a *_test database.'
end

require 'rails/test_help'
require 'webmock/minitest'

OmniAuth.config.test_mode = true
OmniAuth.config.logger = Logger.new(IO::NULL)

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)

    fixtures :all

    teardown { OmniAuth.config.mock_auth[:authentik] = nil }

    def auth_hash(uid:, email: 'person@example.com', name: 'Person', groups: [], slack: nil)
      raw_info = { 'groups' => groups }
      raw_info['slack'] = slack if slack
      OmniAuth::AuthHash.new(
        provider: 'authentik', uid:,
        info: { email:, name:, nickname: email.split('@').first },
        extra: { raw_info: }
      )
    end

    # Sets environment variables for the block, restoring the previous values afterwards.
    def with_env(vars)
      previous = vars.keys.index_with { |key| ENV.fetch(key, nil) }
      vars.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end

    def with_notifications_configured(&)
      with_env({ 'SMTP_ADDRESS' => 'smtp.test', 'SLACK_BOT_TOKEN' => 'xoxb-test' }, &)
    end

    def png_upload(name = 'pixel.png')
      Rack::Test::UploadedFile.new(file_fixture('pixel.png'), 'image/png', original_filename: name)
    end

    def comfy_url(backend, path) = "#{backend.base_url}/#{path}"

    # Stubs what Backend#refresh_inventory! asks for. `models` maps folder names to the files in them.
    # `catalog` is Manager's model list, as entries with filename, save_path and url.
    def stub_inventory(backend, models = {}, downloader: false, manager: nil, catalog: [])
      models = models.transform_keys(&:to_s)
      stub_request(:get, %r{\A#{Regexp.escape(backend.base_url)}/models/\w+\z}).to_return do |request|
        { body: Array(models[request.uri.path.split('/').last]).to_json }
      end
      node = Comfyui::Client::DOWNLOADER_NODE
      stub_request(:get,
                   comfy_url(backend,
                             "object_info/#{node}")).to_return(body: (downloader ? { node => {} } : {}).to_json)
      stub_request(:get,
                   comfy_url(backend, 'v2/manager/version')).to_return(manager ? { body: manager } : { status: 404 })
      stub_request(:get, comfy_url(backend, 'v2/externalmodel/getlist?mode=cache'))
        .to_return(body: { models: catalog }.to_json)
    end
  end
end

module ActionDispatch
  class IntegrationTest
    def sign_in_as(user)
      groups = user.admin? ? [User.admin_group] : []
      OmniAuth.config.mock_auth[:authentik] = auth_hash(uid: user.uid, email: user.email, name: user.name, groups:)
      get '/auth/authentik/callback'
      follow_redirect!
    end
  end
end

require 'test_helper'

# Real Chrome, for what only a browser can show (video actually playing). Locally the browser runs in the
# compose `chrome` service (SELENIUM_REMOTE_URL); in CI it's the runner's own headless Chrome.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  CHROME_ARGS = %w[--autoplay-policy=no-user-gesture-required --mute-audio --disable-dev-shm-usage
                   --window-size=1280,900].freeze

  # One browser, one server port.
  parallelize(workers: 1)

  if ENV['SELENIUM_REMOTE_URL'].present?
    driven_by :selenium, using: :headless_chrome, options: { browser: :remote, url: ENV['SELENIUM_REMOTE_URL'] } do |o|
      CHROME_ARGS.each { o.add_argument(it) unless o.args.include?(it) }
    end
    Capybara.server_host = '0.0.0.0'
    Capybara.server_port = 3010
    Capybara.app_host = "http://#{ENV.fetch('CAPYBARA_APP_HOST', Socket.gethostname)}:3010"
  else
    driven_by :selenium, using: :headless_chrome do |o|
      CHROME_ARGS.each { o.add_argument(it) unless o.args.include?(it) }
    end
  end

  Capybara.default_max_wait_time = 10

  # WebMock blocks real HTTP; the browser and the test server are the exceptions. It stays that way for the rest of
  # the run, because Capybara closes the browser at exit.
  setup do
    remote = URI(ENV['SELENIUM_REMOTE_URL']).host if ENV['SELENIUM_REMOTE_URL'].present?
    WebMock.disable_net_connect!(allow_localhost: true, allow: [remote, ENV.fetch('CAPYBARA_APP_HOST', nil)].compact)
  end

  def sign_in_as(user)
    groups = user.admin? ? [User.admin_group] : []
    OmniAuth.config.mock_auth[:authentik] =
      auth_hash(uid: user.uid, email: user.email, name: user.name, nickname: user.username, groups:)
    visit '/auth/authentik/callback'
  end
end

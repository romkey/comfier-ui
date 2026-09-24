# Password sign-in for running a development instance without Authentik. See DevLogin.
Rails.application.config.x.dev_login =
  if Rails.env.development? && ENV['DEV_LOGIN'] == 'true'
    {
      email: ENV.fetch('DEV_LOGIN_EMAIL', '').strip.downcase,
      password: ENV.fetch('DEV_LOGIN_PASSWORD', ''),
      name: ENV.fetch('DEV_LOGIN_NAME', '').strip.presence || 'Developer',
      admin: ENV.fetch('DEV_LOGIN_ADMIN', 'true') == 'true'
    }
  end

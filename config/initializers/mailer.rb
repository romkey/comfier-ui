# Outgoing email for generation notifications. Email stays off until SMTP_ADDRESS is set.
app_uri = URI.parse(ENV.fetch('APP_URL', 'http://localhost:3000'))
url_options = { host: app_uri.host, protocol: app_uri.scheme }
url_options[:port] = app_uri.port unless app_uri.port == app_uri.default_port

ActiveSupport.on_load(:action_mailer) do
  self.default_url_options = url_options

  if ENV['SMTP_ADDRESS'].present? && !Rails.env.test?
    self.delivery_method = :smtp
    self.smtp_settings = {
      address: ENV.fetch('SMTP_ADDRESS'),
      port: ENV.fetch('SMTP_PORT', 587).to_i,
      user_name: ENV.fetch('SMTP_USERNAME', nil).presence,
      password: ENV.fetch('SMTP_PASSWORD', nil).presence,
      authentication: ENV.fetch('SMTP_AUTHENTICATION', 'plain').presence&.to_sym,
      enable_starttls_auto: ActiveModel::Type::Boolean.new.cast(ENV.fetch('SMTP_ENABLE_STARTTLS', 'true')),
      domain: ENV.fetch('SMTP_DOMAIN', app_uri.host)
    }.compact
  end
end

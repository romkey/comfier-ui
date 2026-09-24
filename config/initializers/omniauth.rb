OmniAuth.config.logger = Rails.logger
OmniAuth.config.allowed_request_methods = %i[post]

# Authentik is the only real identity provider. Tests register it with placeholder settings
# and use OmniAuth's mock mode, so they never hit the network.
authentik_issuer = ENV.fetch('AUTHENTIK_ISSUER') { 'https://authentik.test/application/o/comfier-ui/' if Rails.env.test? }
app_url = ENV.fetch('APP_URL', 'http://localhost:3000')

Rails.application.config.x.authentik_configured = authentik_issuer.present?

Rails.application.config.middleware.use OmniAuth::Builder do
  if authentik_issuer.present?
    provider :openid_connect,
             name: :authentik,
             issuer: authentik_issuer,
             discovery: true,
             scope: %i[openid email profile],
             response_type: :code,
             pkce: true,
             client_options: {
               identifier: ENV.fetch('AUTHENTIK_CLIENT_ID', 'comfier-ui'),
               secret: ENV.fetch('AUTHENTIK_CLIENT_SECRET', nil),
               redirect_uri: "#{app_url.chomp('/')}/auth/authentik/callback"
             }
  end
end

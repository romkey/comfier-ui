source 'https://rubygems.org'

gem 'rails', '~> 8.1.4'

gem 'bootsnap', require: false
gem 'image_processing', '~> 2.2'
gem 'importmap-rails'
# json 3.0 dropped the positional options argument ActiveSupport::JSON.decode still passes (Rails 8.1.3).
gem 'json', '< 3'
gem 'pg', '~> 1.7'
gem 'propshaft'
gem 'puma', '>= 7.0'
gem 'ruby-vips', '~> 2.0', require: false
gem 'stimulus-rails'
# Sits in front of Puma in production: serves result files straight from disk (X-Sendfile), compresses, caches.
gem 'thruster', '~> 0.1.27', require: false
gem 'turbo-rails'
gem 'tzinfo-data', platforms: %i[windows jruby]

# Background jobs and Action Cable. Action Cable's Redis adapter (Rails 8.1.3) requires redis < 6.
gem 'redis', '>= 4', '< 6'
gem 'sidekiq', '~> 8.1'
gem 'sidekiq-cron', '~> 2.3'

# SSO via Authentik (OpenID Connect)
gem 'omniauth', '~> 2.1'
gem 'omniauth_openid_connect', '~> 0.8'
gem 'omniauth-rails_csrf_protection', '~> 2.0'

gem 'pagy', '~> 43.7'

# Agent WebSocket endpoint (Rack hijack) and protocol validation against protocol/agent-v1.schema.json
gem 'faye-websocket', '~> 0.11'
gem 'json_schemer', '~> 2.4'

group :development, :test do
  gem 'brakeman', require: false
  gem 'bundler-audit', require: false
  gem 'debug', platforms: %i[mri windows], require: 'debug/prelude'
  gem 'dotenv-rails'
  gem 'rubocop', require: false
  gem 'rubocop-minitest', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rails', require: false
end

group :development do
  gem 'web-console'
end

group :test do
  # System tests that play real video in Chrome (test/system, bin/rails test:system).
  gem 'capybara'
  gem 'selenium-webdriver'
  gem 'webmock'
end

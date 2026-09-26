redis_url = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
redis = { url: redis_url }

Sidekiq.configure_server do |config|
  config.redis = redis

  config.on(:startup) do
    Sidekiq.logger.info("Sidekiq #{Sidekiq::VERSION} started (Rails #{Rails.env}, Redis #{redis_url})")
    verify_active_storage!
  end
end

def verify_active_storage!
  service = ActiveStorage::Blob.service
  root = service.respond_to?(:root) ? service.root : Rails.root.join('storage')
  FileUtils.mkdir_p(root)
  probe = root.join(".write-probe-#{Process.pid}")
  File.write(probe, 'ok')
  File.delete(probe)
  Sidekiq.logger.info("Active Storage ready at #{root}")
rescue StandardError => e
  path = defined?(root) && root ? root : '(unknown)'
  Sidekiq.logger.error("Active Storage NOT writable at #{path}: #{e.class}: #{e.message}")
end

Sidekiq.configure_client { |config| config.redis = redis }

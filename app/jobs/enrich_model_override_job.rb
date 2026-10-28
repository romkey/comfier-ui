# Fills in a model override's file size and sha256 from its download link, for disk checks and progress.
class EnrichModelOverrideJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(override)
    return if override.url.blank? || override.bytes.present?

    attrs = ModelLinkHead.attributes(override.url, known_sha256: override.sha256)
    override.update!(attrs) if attrs.present?
  rescue StandardError => e
    Rails.logger.info("[Agent] couldn't enrich override #{override.id} (#{override.url}): #{e.class}: #{e.message}")
  end
end

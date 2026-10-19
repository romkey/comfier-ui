# frozen_string_literal: true

# Fills in file sizes and sha256 hashes for a workflow's models with a HEAD request to each link.
# Hugging Face `resolve` links report the LFS hash and size in X-Linked-Etag / X-Linked-Size.
# For fp8 files it also looks for the official fp16 version, which Apple Silicon servers use instead.
class EnrichWorkflowModelsJob < ApplicationJob
  queue_as :default

  def perform(workflow)
    workflow.workflow_models.where.not(url: [nil, '']).where(bytes: nil).find_each { enrich(it) }
    found = workflow.workflow_models.where.not(url: [nil, '']).where(fp16_checked_at: nil).map { find_fp16(it) }
    RecomputeAvailabilityJob.perform_later(workflow_id: workflow.id) if found.any?
  end

  private

  def enrich(model)
    response = head(model.url)
    return unless found?(response)

    attrs = attributes_from(response, model.sha256)
    model.update!(attrs.merge(source: model.source == 'admin' ? 'admin' : 'enriched')) if attrs.any?
  rescue StandardError => e
    Rails.logger.info("[Agent] couldn't enrich #{model.url}: #{e.class}: #{e.message}")
  end

  # Model repos that publish fp8 files usually publish fp16 ones beside them under the same name.
  def find_fp16(model)
    return unless Agent::MacWeights.convertible?(model.filename)

    url = Agent::MacWeights.fp16_url_guess(model.url, model.filename)
    response = url && head(url)
    attrs = found?(response) ? { fp16_url: url, **attributes_from(response, nil).transform_keys { :"fp16_#{it}" } } : {}
    model.update!(attrs.merge(fp16_checked_at: Time.current))
    attrs.any?
  rescue StandardError => e
    Rails.logger.info("[Agent] couldn't look for an fp16 version of #{model.url}: #{e.class}: #{e.message}")
    false
  end

  def found?(response) = response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)

  # A redirect's own Content-Length is the redirect body, not the file.
  def attributes_from(response, known_sha256)
    size = response['x-linked-size'] || (response['content-length'] unless response.is_a?(Net::HTTPRedirection))
    etag = response['x-linked-etag'].to_s.delete('"')
    attrs = { bytes: size&.to_i }.compact
    attrs[:sha256] = etag if etag.match?(/\A\h{64}\z/) && known_sha256.blank?
    attrs
  end

  def head(url)
    uri = URI.parse(url)
    return unless uri.is_a?(URI::HTTPS)

    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
      http.head(uri.request_uri, 'User-Agent' => 'Comfier')
    end
  end
end

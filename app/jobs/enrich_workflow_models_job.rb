# frozen_string_literal: true

# Fills in file sizes and sha256 hashes for a workflow's models with a HEAD request to each link (ModelLinkHead).
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
    attrs = ModelLinkHead.attributes(model.url, known_sha256: model.sha256)
    model.update!(attrs.merge(source: model.source == 'admin' ? 'admin' : 'enriched')) if attrs.present?
  rescue StandardError => e
    Rails.logger.info("[Agent] couldn't enrich #{model.url}: #{e.class}: #{e.message}")
  end

  # Model repos that publish fp8 files usually publish fp16 ones beside them under the same name.
  def find_fp16(model)
    return unless Agent::MacWeights.convertible?(model.filename)

    url = Agent::MacWeights.fp16_url_guess(model.url, model.filename)
    found = url && ModelLinkHead.attributes(url)
    attrs = found ? { fp16_url: url, **found.transform_keys { :"fp16_#{it}" } } : {}
    model.update!(attrs.merge(fp16_checked_at: Time.current))
    attrs.any?
  rescue StandardError => e
    Rails.logger.info("[Agent] couldn't look for an fp16 version of #{model.url}: #{e.class}: #{e.message}")
    false
  end
end

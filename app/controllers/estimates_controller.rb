# "Estimated: about 2 min on studio-4090, starts in about 5 min (3 jobs ahead)" for the studio
# form, plus the privacy notice when the job may run on someone else's server.
class EstimatesController < ApplicationController
  include ServersHelper

  def show
    generation = build_generation
    return render(json: { summary: nil, notice: nil }) unless generation&.workflow

    candidates = Agent::Router.new(generation).candidates
    best = candidates.min_by(&:finish_at)
    render json: { summary: best && summary(best), notice: notice(candidates) }
  end

  private

  def build_generation
    workflow = Workflow.enabled.find_by(id: params.dig(:generation, :workflow_id))
    return unless workflow

    attrs = params.fetch(:generation, {}).permit(:aspect_ratio, :duration, :quality, :batch_size, :cfg_level)
    generation = current_user.generations.new(attrs.merge(workflow:, pinned_backend_id: usable_pinned_id))
    generation.valid?
    generation.structure_hash = workflow.structure_hash
    generation.work_units = Agent::WorkUnits.compute(generation)
    generation
  end

  def usable_pinned_id
    pinned = Backend.find_by(id: params.dig(:generation, :pinned_backend_id).presence)
    pinned.id if pinned && BackendPolicy.new(current_user).can_use?(pinned)
  end

  def summary(candidate)
    prediction = candidate.prediction
    ahead = queue_ahead(candidate.backend)
    run = duration_estimate(prediction.total_ms, confidence: prediction.confidence, p90_ms: prediction.p90_ms)
    start = candidate.finish_at - (prediction.total_ms / 1000.0)
    text = "Estimated: #{run} on #{candidate.backend.name}"
    text += ", starts #{eta_phrase(start)} (#{ahead} #{'job'.pluralize(ahead)} ahead)" if ahead.positive?
    text
  end

  def queue_ahead(backend)
    if backend.agent?
      backend.generations.agent_waiting.count + backend.generations.agent_on_server.count
    else
      backend.generations.where(status: %w[queued running], agent_state: nil).count
    end
  end

  def notice(candidates)
    owners = candidates.map(&:backend).reject { it.owned_by?(current_user) }.filter_map(&:owner_user).uniq
    return if owners.empty?

    names = owners.map { "#{it.display_name}'s" }.to_sentence(two_words_connector: ' or ', last_word_connector: ', or ')
    "This may run on #{names} server. The server owner can see your prompt, images, and results."
  end
end

# Sends a queued generation to a server through whichever runner handles it.
class SubmitGenerationJob < ApplicationJob
  queue_as :default

  # API submission creates the generation and its idempotency receipt in one transaction.
  self.enqueue_after_transaction_commit = true

  def perform(generation)
    return unless generation.queued? && generation.agent_state.nil?
    return generation.fail!('The workflow for this generation was removed') if generation.workflow.nil?

    Backends::Runner.for(generation).submit(generation)
  rescue BackendSelector::NoBackendAvailable, Agent::Router::UnroutableError, Comfyui::Error,
         WorkflowRenderer::MissingValue => e
    fail_generation(generation, e.message)
  end

  private

  def fail_generation(generation, message)
    return generation.fail!(message) unless generation.agent_job?

    generation.agent_transition!(from: Generation::WAITING_STATES, to: 'failed', error_message: message.truncate(1000))
  end
end

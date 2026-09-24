# Sends a queued generation's workflow to a ComfyUI backend, then hands off to polling.
class SubmitGenerationJob < ApplicationJob
  queue_as :default

  def perform(generation)
    return unless generation.queued?
    return generation.fail!('The workflow for this generation was removed') if generation.workflow.nil?

    backend = BackendSelector.call(generation.user, generation.workflow)
    client = backend.client
    image = upload_input_image(client, generation) if generation.input_image.attached?
    graph = WorkflowRenderer.render(generation.workflow.graph, generation.placeholder_values(image:))
    prompt_id = client.submit(graph)

    generation.update!(backend:, comfy_prompt_id: prompt_id, status: :running, submitted_at: Time.current)
    PollGenerationJob.set(wait: PollGenerationJob::INTERVAL).perform_later(generation)
  rescue BackendSelector::NoBackendAvailable, Comfyui::Error, WorkflowRenderer::MissingValue => e
    generation.fail!(e.message)
  end

  private

  def upload_input_image(client, generation)
    blob = generation.input_image.blob
    blob.open do |file|
      client.upload_image(file, filename: "comfier-#{generation.id}-#{blob.filename.sanitized}",
                                content_type: blob.content_type)
    end
  end
end

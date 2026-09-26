# Sends a queued generation's workflow to a ComfyUI backend, then hands off to polling.
class SubmitGenerationJob < ApplicationJob
  queue_as :default

  def perform(generation)
    return unless generation.queued?
    return generation.fail!('The workflow for this generation was removed') if generation.workflow.nil?

    mark_running!(generation, **submit_workflow(generation))
  rescue BackendSelector::NoBackendAvailable, Comfyui::Error, WorkflowRenderer::MissingValue => e
    generation.fail!(e.message)
  end

  private

  def submit_workflow(generation)
    backend = BackendSelector.call(generation.user, generation.workflow)
    client = backend.client
    image = upload_input_image(client, generation) if generation.input_image.attached?
    graph = WorkflowRenderer.render(generation.workflow.graph, generation.placeholder_values(image:))
    prompt_id = client.submit(graph)
    parameters = generation.parameters
    parameters = parameters.merge('backend_input_image' => image) if image

    { backend:, prompt_id:, parameters: }
  end

  def mark_running!(generation, backend:, prompt_id:, parameters:)
    generation.update!(backend:, comfy_prompt_id: prompt_id, status: :running, submitted_at: Time.current,
                       parameters:)
    PollGenerationJob.set(wait: PollGenerationJob::INTERVAL).perform_later(generation)
  end

  def upload_input_image(client, generation)
    blob = generation.input_image.blob
    blob.open do |file|
      client.upload_image(file, filename: "comfier-#{generation.id}-#{blob.filename.sanitized}",
                                content_type: blob.content_type)
    end
  end
end

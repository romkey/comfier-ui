module Backends
  # ComfyUI servers the frontend calls over HTTP and polls.
  class LegacyRunner
    def submit(generation)
      backend = BackendSelector.call(generation.user, generation.workflow)
      submit_to(generation, backend)
    end

    def submit_to(generation, backend)
      client = backend.client
      image = upload_input_image(client, generation) if generation.input_image.attached?
      graph = graph_for_legacy(generation, uploaded_image: image)
      prompt_id = client.submit(graph)
      parameters = image ? generation.parameters.merge('backend_input_image' => image) : generation.parameters
      generation.update!(backend:, comfy_prompt_id: prompt_id, status: :running, submitted_at: Time.current,
                         parameters:, agent_state: nil, agent_phase: nil)
      PollGenerationJob.set(wait: PollGenerationJob::INTERVAL).perform_later(generation)
    end

    def cancel(generation)
      if generation.running? && generation.backend && generation.comfy_prompt_id.present?
        generation.backend.client.cancel_prompt(generation.comfy_prompt_id)
      end
    rescue Comfyui::Error
      # Still mark it cancelled locally; polling will stop and ComfyUI may finish on its own.
    ensure
      generation.fail!(Generation::CANCELLED_MESSAGE)
    end

    def refresh_inventory(backend) = backend.refresh_inventory!

    def download(backend, requirements, **) = ModelInstaller.queue(backend, requirements)

    private

    def upload_input_image(client, generation)
      blob = generation.input_image.blob
      blob.open do |file|
        client.upload_image(file, filename: "comfier-#{generation.id}-#{blob.filename.sanitized}",
                                  content_type: blob.content_type)
      end
    end

    # Agent submission stores comfier-input:// refs in filled_workflow_json; legacy ComfyUI needs filenames.
    def graph_for_legacy(generation, uploaded_image:)
      if generation.input_image.attached?
        return WorkflowRenderer.render(generation.workflow.graph,
                                       generation.placeholder_values(image: uploaded_image))
      end

      filled = generation.filled_workflow_json
      return filled if filled.present? && !agent_input_refs?(filled)

      WorkflowRenderer.render(generation.workflow.graph, generation.placeholder_values)
    end

    def agent_input_refs?(graph)
      JSON.generate(graph).include?('comfier-input://')
    end
  end
end

module Comfyui
  # Removes a finished generation's files and history from ComfyUI when the backend opts in.
  class GenerationCleaner
    def self.call(generation) = new(generation).call

    def initialize(generation)
      @generation = generation
    end

    def call
      backend = @generation.backend
      prompt_id = @generation.comfy_prompt_id
      return unless backend&.cleanup_after_run? && prompt_id.present?

      result = backend.client.result(prompt_id)
      backend.client.cleanup_run(
        prompt_id:,
        files: result.pending? ? [] : result.all_files,
        input_image: @generation.parameters['backend_input_image']
      )
    rescue Comfyui::Error => e
      Rails.logger.warn("Couldn't clean up generation #{@generation.id} on #{backend&.name}: #{e.message}")
    end
  end
end

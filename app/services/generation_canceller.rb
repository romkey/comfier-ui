# Marks a generation cancelled and asks ComfyUI to drop it when it was already submitted.
class GenerationCanceller
  Outcome = Data.define(:cancelled)

  def self.call(generation) = new(generation).call

  def initialize(generation)
    @generation = generation
  end

  def call
    return Outcome.new(cancelled: false) unless @generation.in_progress?

    cancel_on_comfyui if @generation.running? && @generation.backend && @generation.comfy_prompt_id.present?
    @generation.fail!(Generation::CANCELLED_MESSAGE)
    Outcome.new(cancelled: true)
  end

  private

  def cancel_on_comfyui
    @generation.backend.client.cancel_prompt(@generation.comfy_prompt_id)
  rescue Comfyui::Error
    # Still mark it cancelled locally; polling will stop and ComfyUI may finish on its own.
  end
end

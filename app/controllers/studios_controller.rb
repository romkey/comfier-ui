# The Image / Video / Audio / 3D Model pages: a simplified form plus the user's recent work.
class StudiosController < ApplicationController
  include StudioPage
  include GenerationReferenceReuse

  # Settings that carry over when the user picks another style (sent as carry[...] by the style switch).
  CARRIED = %i[prompt negative_prompt aspect_ratio duration quality cfg_level denoise lyrics batch_size seed
               pinned_backend_id].freeze

  def show
    source = source_generation
    load_studio(GenerationKind.find(params.require(:kind)), workflow_id: params[:workflow_id] || source&.workflow_id)
    @generation = build_generation(source)
    apply_reference_from_source(source)
    @needs_input = switched_style? ? StudioInputs.missing(@workflow, @generation, @reference_sources) : []
  end

  private

  def source_generation
    current_user.generations.find_by(id: params[:from]) if params[:from]
  end

  def build_generation(source)
    defaults = { negative_prompt: current_user.default_negative_prompt,
                 aspect_ratio: current_user.default_aspect_ratio }
    generation = current_user.generations.new(defaults.merge(source&.reusable_attributes || {}, carried,
                                                             workflow_id: @workflow&.id))
    generation.pinned_backend_id = nil unless pin_allowed?(generation)
    generation
  end

  def switched_style? = params.key?(:carry)

  # What the form held under the previous style. Blank fields don't override the defaults.
  def carried
    return {} unless switched_style?

    values = params.expect(carry: CARRIED).to_h.compact_blank.symbolize_keys
    values[:denoise] = values[:denoise].to_f / 100.0 if values[:denoise]
    values
  end

  # A server picked for the previous style may not run this one.
  def pin_allowed?(generation)
    return true if generation.pinned_backend_id.blank? || @workflow.nil?

    backend = Backend.find_by(id: generation.pinned_backend_id)
    backend.present? && StudioServerPin.new(@workflow, current_user).pinnable?(backend)
  end
end

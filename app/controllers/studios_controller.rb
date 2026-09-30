# The Image / Video / Audio / 3D Model pages: a simplified form plus the user's recent work.
class StudiosController < ApplicationController
  include StudioPage
  include GenerationReferenceReuse

  def show
    source = source_generation
    load_studio(GenerationKind.find(params.require(:kind)), workflow_id: params[:workflow_id] || source&.workflow_id)
    @generation = build_generation(source)
    apply_reference_from_source(source)
  end

  private

  def source_generation
    current_user.generations.find_by(id: params[:from]) if params[:from]
  end

  def build_generation(source)
    defaults = { negative_prompt: current_user.default_negative_prompt,
                 aspect_ratio: current_user.default_aspect_ratio }
    current_user.generations.new(defaults.merge(source&.reusable_attributes || {},
                                                workflow_id: @workflow&.id))
  end
end

# The Image / Video / Audio / 3D Model pages: a simplified form plus the user's recent work.
class StudiosController < ApplicationController
  include StudioPage

  def show
    source = source_generation
    load_studio(GenerationKind.find(params.require(:kind)), workflow_id: params[:workflow_id] || source&.workflow_id)
    @generation = build_generation(source)
    attach_reference_from(source)
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

  def attach_reference_from(source)
    return unless source && @workflow&.uses?(:image) && source.succeeded? && source.outputs.any?

    @generation.input_image.attach(source.outputs.first.blob)
  end
end

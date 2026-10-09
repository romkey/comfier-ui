# Which inputs a studio style needs that the form doesn't have yet, so that after switching styles the
# form can point them out rather than leave them to a failed submit.
module StudioInputs
  # Whether each input is filled in; checked only for styles that use it. In form order.
  FILLED = {
    image: ->(generation, reference_sources) { generation.input_image.attached? || reference_sources.present? },
    prompt: ->(generation, _) { generation.prompt.present? },
    lyrics: ->(generation, _) { generation.lyrics.present? }
  }.freeze

  module_function

  def missing(workflow, generation, reference_sources = nil)
    return [] unless workflow

    FILLED.filter_map do |field, filled|
      field if workflow.uses?(field) && !filled.call(generation, reference_sources)
    end
  end
end

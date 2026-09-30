# Prefills and reapplies reference images when tweaking from an earlier result.
module GenerationReferenceReuse
  private

  def apply_reference_from_source(source)
    @source_generation = source
    return unless source && @workflow&.uses?(:image)

    @reference_sources = GenerationReference.available_sources(source)
    return if @reference_sources.empty?

    @reference_source = params[:reference].presence_in(@reference_sources) ||
                        params.dig(:generation, :reference_source).presence_in(@reference_sources) ||
                        GenerationReference.default_source(source)
    GenerationReference.attach!(@generation, source:, source_type: @reference_source)
  end

  def reapply_reference_after_failed_create
    from_id = reference_reuse_params[:from_id]
    return if from_id.blank?

    source = current_user.generations.find_by(id: from_id)
    apply_reference_from_source(source)
  end

  def attach_reused_reference(generation)
    GenerationReference.attach_from_form!(
      generation,
      user: current_user,
      from_id: reference_reuse_params[:from_id],
      source_type: reference_reuse_params[:source_type]
    )
  end

  def reference_reuse_params
    raw = params[:generation]
    return {} unless raw

    { from_id: raw[:reference_from_id], source_type: raw[:reference_source] }
  end
end

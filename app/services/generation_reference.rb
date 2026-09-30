# Reuses a prior generation's uploaded reference or output when tweaking or resubmitting.
class GenerationReference
  SOURCES = %w[original result].freeze

  class << self
    def available_sources(generation)
      return [] unless generation

      [].tap do |sources|
        sources << 'original' if generation.input_image.attached?
        sources << 'result' if generation.succeeded? && generation.outputs.any?
      end
    end

    def default_source(generation)
      sources = available_sources(generation)
      return 'result' if sources.include?('result')
      return 'original' if sources.include?('original')

      nil
    end

    def attach!(target, source:, source_type:)
      return unless target.workflow&.uses?(:image)

      blob = blob_for(source, source_type)
      return unless blob

      target.input_image.attach(blob)
    end

    def attach_from_form!(target, user:, from_id:, source_type:)
      return if target.input_image.attached?
      return unless target.workflow&.uses?(:image)
      return if from_id.blank?

      source = user.generations.find_by(id: from_id)
      return unless source

      type = source_type.presence_in(SOURCES) || default_source(source)
      attach!(target, source:, source_type: type)
    end

    def blob_for(source, source_type)
      case source_type.to_s
      when 'original'
        source.input_image.blob if source.input_image.attached?
      when 'result'
        source.outputs.first.blob if source.succeeded? && source.outputs.any?
      end
    end
  end
end

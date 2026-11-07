module Api
  module V1
    # Describe studio controls rather than exposing the workflow graph or server configuration.
    class WorkflowInputs
      def initialize(workflow)
        @workflow = workflow
      end

      def as_json
        fields = {}
        add_text(fields)
        add_choices(fields)
        add_numbers(fields)
        fields['input_image'] = { type: 'file', required: true } if @workflow.uses?(:image)
        fields
      end

      private

      def add_text(fields)
        %w[prompt negative_prompt lyrics].each do |name|
          next unless @workflow.uses?(name)

          fields[name] = { type: 'string', required: name != 'negative_prompt', max_length: 10_000 }
        end
      end

      def add_choices(fields)
        choices = {
          'aspect_ratio' => [%i[width height], Generation::ASPECT_RATIOS],
          'quality' => [[:steps], Generation::QUALITIES],
          'cfg_level' => [[:cfg], Generation::CFG_LEVELS]
        }
        choices.each do |name, (placeholders, values)|
          fields[name] = { type: 'string', required: false, enum: values } if @workflow.uses?(*placeholders)
        end
      end

      def add_numbers(fields)
        {
          'seed' => [[:seed], 'integer', 0, Generation::MAX_SEED],
          'duration' => [%i[duration frames fps], 'number', Generation::DURATION_RANGE.min, Generation::DURATION_RANGE.max],
          'denoise' => [[:denoise], 'number', Generation::DENOISE_RANGE.min, Generation::DENOISE_RANGE.max],
          'batch_size' => [[:batch_size], 'integer', Generation::BATCH_RANGE.min, Generation::BATCH_RANGE.max]
        }.each do |name, (placeholders, type, minimum, maximum)|
          next unless @workflow.uses?(*placeholders)

          fields[name] = { type:, required: false, minimum:, maximum: }
        end
      end
    end
  end
end

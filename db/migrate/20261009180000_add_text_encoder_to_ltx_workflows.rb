# LTX-2.3 conversions ship without their Gemma text encoder, and the first MLX video presets didn't name
# one, so their jobs failed with "Config file not found". Existing LTX-2.3 recipes get the text encoder
# the presets now use, and the memory the pair needs (a 22B video model plus a 12B encoder).
class AddTextEncoderToLtxWorkflows < ActiveRecord::Migration[8.1]
  TEXT_ENCODER = 'mlx-community/gemma-3-12b-it-bf16'.freeze
  MIN_MEMORY_GB = 96

  class MigrationWorkflow < ActiveRecord::Base
    self.table_name = 'workflows'
  end

  def up
    MigrationWorkflow.where(engine: 'mlx_video').find_each do |workflow|
      recipe = workflow.graph
      next unless recipe.is_a?(Hash) && recipe['command'].to_s.start_with?('mlx_video.ltx_2.')
      next unless recipe['model_repo'].to_s.match?(/LTX-2\.3/i)
      next if recipe['text_encoder_repo'].present? && !recipe['text_encoder_repo'].casecmp?('Lightricks/LTX-2')

      memory = [recipe['min_memory_gb'].to_i, MIN_MEMORY_GB].max
      updated = recipe.merge('text_encoder_repo' => TEXT_ENCODER, 'min_memory_gb' => memory)
      workflow.update_columns(graph: updated) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down; end
end

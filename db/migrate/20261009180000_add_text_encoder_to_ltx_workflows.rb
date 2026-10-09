# LTX-2.3 conversions ship without their Gemma text encoder, and the first MLX video presets didn't name
# one, so their jobs failed with "Config file not found". Existing LTX-2.3 recipes get the text encoder
# the presets now use.
class AddTextEncoderToLtxWorkflows < ActiveRecord::Migration[8.1]
  TEXT_ENCODER = 'mlx-community/gemma-3-12b-it-bf16'.freeze

  class MigrationWorkflow < ActiveRecord::Base
    self.table_name = 'workflows'
  end

  def up
    MigrationWorkflow.where(engine: 'mlx_video').find_each do |workflow|
      recipe = workflow.graph
      next unless recipe.is_a?(Hash) && recipe['command'].to_s.start_with?('mlx_video.ltx_2.')
      next unless recipe['model_repo'].to_s.match?(/LTX-2\.3/i)
      next if recipe['text_encoder_repo'].present? && !recipe['text_encoder_repo'].casecmp?('Lightricks/LTX-2')

      workflow.update_columns(graph: recipe.merge('text_encoder_repo' => TEXT_ENCODER)) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down; end
end

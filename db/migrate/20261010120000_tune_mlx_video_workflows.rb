# The first MLX video presets gave poor video:
# - LTX and Wan2.2 TI2V write 24 fps, but styles kept the 16 fps frame rate, so frames were counted for
#   16 fps and played 1.5x fast. LTX recipes now write {{fps}} and styles left at 16 move to 24.
# - LTX "dev" ran full size in one pass with the style's default guidance of 7 (LTX wants about 3). It
#   becomes "dev-two-stage" (half size with guidance, then upscaled and refined with the distilled LoRA,
#   as ComfyUI's templates do), with guidance and steps moved to LTX's defaults if they were never changed.
# - Two-stage pipelines get the x2 1.1 spatial upscaler instead of 1.0, which mlx-video picks first.
class TuneMlxVideoWorkflows < ActiveRecord::Migration[8.1]
  UPSCALER = 'ltx-2.3-spatial-upscaler-x2-1.1.safetensors'.freeze
  TWO_STAGE = %w[distilled dev-two-stage dev-two-stage-hq].freeze

  class MigrationWorkflow < ActiveRecord::Base
    self.table_name = 'workflows'
  end

  def up
    MigrationWorkflow.where(engine: 'mlx_video').find_each do |workflow|
      recipe = workflow.graph
      next unless recipe.is_a?(Hash)

      command = recipe['command'].to_s
      if command.start_with?('mlx_video.ltx_2.')
        tune_ltx(workflow, recipe)
      elsif command.start_with?('mlx_video.wan_2.') && recipe['model_dir'].to_s.match?(/ti2v/i)
        workflow.update_columns(frame_rate: 24) if workflow.frame_rate == 16 # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end

  def down; end

  private

  def tune_ltx(workflow, recipe)
    columns = {}
    recipe = recipe.merge('fps' => '{{fps}}') if recipe['fps'].is_a?(Numeric)
    columns[:frame_rate] = 24 if workflow.frame_rate == 16
    if recipe['pipeline'] == 'dev'
      recipe = recipe.merge('pipeline' => 'dev-two-stage')
      columns[:guidance] = 3.0 if (workflow.guidance - 7.0).abs < 0.01
      columns[:steps] = 30 if workflow.steps == 20
    end
    recipe = recipe.merge('spatial_upscaler' => UPSCALER) if two_stage?(recipe) && ltx_23?(recipe)
    workflow.update_columns(graph: recipe, **columns) # rubocop:disable Rails/SkipsModelValidations
  end

  def two_stage?(recipe) = TWO_STAGE.include?(recipe['pipeline'] || 'distilled') && recipe['spatial_upscaler'].blank?
  def ltx_23?(recipe) = recipe['model_repo'].to_s.match?(/LTX-2\.3/i)
end

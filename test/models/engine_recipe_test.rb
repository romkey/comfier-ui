require 'test_helper'

class EngineRecipeTest < ActiveSupport::TestCase
  RECIPE = { 'command' => 'mflux-generate-z-image-turbo', 'model' => 'z-image-turbo', 'quantize' => 8,
             'prompt' => '{{prompt}}', 'image' => ['{{image}}', '{{denoise}}'], 'vae_tiling' => true }.freeze

  test 'a recipe with a command, a model and flag options is fine' do
    assert_empty EngineRecipe.problems('mflux', RECIPE)
  end

  test 'the command has to belong to the engine' do
    assert_match(/needs "command"/, EngineRecipe.problems('mflux', RECIPE.merge('command' => 'rm -rf /')).first)
    assert_match(/needs "command"/, EngineRecipe.problems('mlx_video', RECIPE).first)
    assert_empty EngineRecipe.problems('mlx_video', { 'command' => 'mlx_video.ltx_2.generate', 'prompt' => 'x' })
  end

  test 'mflux recipes name their model' do
    assert_includes EngineRecipe.problems('mflux', RECIPE.except('model')), 'needs "model"'
  end

  test 'options are flag names with plain values, and the agent owns the output path' do
    problems = EngineRecipe.problems('mflux', RECIPE.merge('Bad-Key' => 1, 'nested' => { 'a' => 1 }, 'output' => 'x'))

    assert_equal 3, problems.size
    assert(problems.any? { it.include?('Bad-Key') })
    assert(problems.any? { it.include?('"nested" must be') })
    assert_includes problems, '"output" is set by the agent'
  end

  test 'min_memory_gb and model' do
    assert_equal 16, EngineRecipe.min_memory_gb(RECIPE.merge('min_memory_gb' => 16))
    assert_nil EngineRecipe.min_memory_gb(RECIPE.merge('min_memory_gb' => 'lots'))
    assert_equal 'z-image-turbo', EngineRecipe.model(RECIPE)
  end

  test 'every preset is a valid workflow for its page' do
    EnginePreset::ALL.each do |preset|
      workflow = Workflow.new(name: preset.label, kind: preset.kind, engine: preset.engine,
                              graph_json: preset.to_json_text)

      assert_predicate workflow, :valid?, "#{preset.key}: #{workflow.errors.full_messages.to_sentence}"
    end
  end
end

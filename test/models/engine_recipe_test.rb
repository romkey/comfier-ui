require 'test_helper'

class EngineRecipeTest < ActiveSupport::TestCase
  RECIPE = { 'command' => 'mflux-generate-z-image-turbo', 'model' => 'z-image-turbo', 'quantize' => 8,
             'prompt' => '{{prompt}}', 'image' => ['{{image}}', '{{denoise}}'], 'vae_tiling' => true }.freeze

  test 'a recipe with a command, a model and flag options is fine' do
    assert_empty EngineRecipe.problems('mflux', RECIPE)
  end

  test 'the command has to belong to the engine' do
    assert_match(/needs "command"/, EngineRecipe.problems('mflux', RECIPE.merge('command' => 'rm -rf /')).first)
    assert_match(/is for mflux/, EngineRecipe.problems('mlx_video', RECIPE).first)
    assert_empty EngineRecipe.problems('mlx_video', { 'command' => 'mlx_video.ltx_2.generate', 'prompt' => 'x' })
  end

  test 'a recipe for another engine says which' do
    problem = EngineRecipe.problems('mlx_video', RECIPE).first

    assert_match(/is for mflux/, problem)
    assert_match(/set Runs on to mflux/, problem)
  end

  test 'MLX video recipes name a Hugging Face repo, not a model' do
    ltx = { 'command' => 'mlx_video.ltx_2.generate', 'prompt' => '{{prompt}}' }

    assert_match(/can't use "model" for MLX video/,
                 EngineRecipe.problems('mlx_video', ltx.merge('model' => 'z-image-turbo')).join)
    assert_match(/must be a Hugging Face repo/,
                 EngineRecipe.problems('mlx_video', ltx.merge('model_repo' => 'z-image-turbo')).join)
    assert_empty EngineRecipe.problems('mlx_video', ltx.merge('model_repo' => 'prince-canuma/LTX-2.3-distilled',
                                                              'text_encoder_repo' => EngineRecipe::LTX_TEXT_ENCODER))
  end

  test 'LTX-2.3 recipes name a working text encoder' do
    ltx = { 'command' => 'mlx_video.ltx_2.generate', 'model_repo' => 'prince-canuma/LTX-2.3-distilled' }

    assert_match(/needs "text_encoder_repo"/, EngineRecipe.problems('mlx_video', ltx).join)
    assert_match(/every prompt gives the same video/,
                 EngineRecipe.problems('mlx_video', ltx.merge('text_encoder_repo' => 'Lightricks/LTX-2')).join)
    assert_empty EngineRecipe.problems('mlx_video', ltx.merge('text_encoder_repo' => EngineRecipe::LTX_TEXT_ENCODER))
    assert_equal ['prince-canuma/LTX-2.3-distilled', EngineRecipe::LTX_TEXT_ENCODER],
                 EngineRecipe.models(ltx.merge('text_encoder_repo' => EngineRecipe::LTX_TEXT_ENCODER), 'mlx_video')
  end

  test "an engine's model comes from its own key" do
    assert_equal 'z-image-turbo', EngineRecipe.model({ 'model' => 'z-image-turbo' }, 'mflux')
    assert_nil EngineRecipe.model({ 'model' => 'z-image-turbo' }, 'mlx_video')
    assert_equal 'org/repo', EngineRecipe.model({ 'model_repo' => 'org/repo' }, 'mlx_video')
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
    assert_equal 'prince-canuma/LTX-2.3-distilled',
                 EngineRecipe.model({ 'command' => 'mlx_video.ltx_2.generate',
                                      'model_repo' => 'prince-canuma/LTX-2.3-distilled' })
    assert_nil EngineRecipe.model({ 'command' => 'mlx_video.wan_2.generate', 'model_dir' => '~/wan' })
  end

  test 'every preset is a valid workflow for its page' do
    EnginePreset::ALL.each do |preset|
      workflow = Workflow.new(name: preset.label, kind: preset.kind, engine: preset.engine,
                              graph_json: preset.to_json_text)

      assert_predicate workflow, :valid?, "#{preset.key}: #{workflow.errors.full_messages.to_sentence}"
    end
  end
end

require 'test_helper'

module Agent
  class SubmissionTest < ActiveSupport::TestCase
    setup do
      bring_mac_online!(create_agent_backend!(owner: users(:alice), name: 'Mac Studio'),
                        engines: { mlx_video: { models: [] } }, ram_gb: 128)
    end

    test 'drops recipe options left blank so the tool keeps its default' do
      workflow = engine_workflow!(name: 'LTX dev', preset: 'ltx-2.3-dev')
      generation = users(:alice).generations.create!(workflow:, prompt: 'A red fox', negative_prompt: '', duration: '5')

      Submission.enqueue!(generation)
      recipe = generation.reload.filled_workflow_json

      assert_not recipe.key?('negative_prompt')
      assert_equal 'A red fox', recipe['prompt']
      assert_equal [121, 24, 3.0, 30], recipe.values_at('num_frames', 'fps', 'cfg_scale', 'steps')
      assert_equal 'dev-two-stage', recipe['pipeline']
    end

    test 'keeps a negative prompt the user wrote' do
      workflow = engine_workflow!(name: 'LTX dev', preset: 'ltx-2.3-dev')
      generation = users(:alice).generations.create!(workflow:, prompt: 'A red fox', negative_prompt: 'blurry')

      Submission.enqueue!(generation)

      assert_equal 'blurry', generation.reload.filled_workflow_json['negative_prompt']
    end
  end
end

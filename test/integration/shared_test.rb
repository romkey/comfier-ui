require 'test_helper'

class SharedTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:bob) }

  test 'the shared gallery lists results others chose to share' do
    generations(:alice_done).share!(share_prompt: true, share_input: false)

    get shared_index_path

    assert_response :success
    assert_select '.result-card', minimum: 1
    assert_select 'a', text: /lighthouse/i
  end

  test 'a shared detail shows the prompt when the sharer included it' do
    generation = generations(:alice_done)
    generation.share!(share_prompt: true)

    get shared_path(generation)

    assert_response :success
    assert_select 'p', text: /lighthouse at dusk/
    assert_select 'a', text: 'Try this prompt'
  end

  test 'a shared detail hides the prompt when the sharer left it out' do
    generation = generations(:alice_done)
    generation.share!(share_prompt: false)

    get shared_path(generation)

    assert_response :success
    assert_select 'a', text: 'Try this prompt', count: 0
  end

  test 'members can share and unshare their own results' do
    sign_in_as users(:alice)
    generation = generations(:alice_done)

    patch share_generation_path(generation),
          params: { share_result: '1', share_prompt: '1', share_input: '0' },
          as: :turbo_stream

    assert_response :success
    assert_predicate generation.reload, :shared?

    patch share_generation_path(generation), params: { share_result: '0' }, as: :turbo_stream

    assert_response :success
    assert_not generation.reload.shared?
  end

  test 'creating with share result checked stores share intent until the job finishes' do
    sign_in_as users(:alice)
    workflow = workflows(:sd_image)

    assert_difference -> { Generation.count }, 1 do
      post generations_path, params: {
        generation: {
          workflow_id: workflow.id,
          prompt: 'A shared sunset',
          share_result: '1',
          share_prompt: '1',
          share_input: '0'
        }
      }
    end

    generation = Generation.order(:id).last

    assert_predicate generation, :share_when_done?
    assert_predicate generation, :share_prompt?
    assert_not generation.share_input?
    assert_not generation.shared?
  end

  test 'admins can remove someone else’s share' do
    generations(:alice_done).share!
    sign_in_as users(:admin)

    delete unshare_shared_path(generations(:alice_done))

    assert_redirected_to shared_index_path
    assert_not generations(:alice_done).reload.shared?
  end
end

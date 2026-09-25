require 'test_helper'

class GenerationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in_as users(:alice)
  end

  test 'creating a generation queues it and returns to the studio' do
    assert_difference('users(:alice).generations.count', 1) do
      assert_enqueued_with(job: SubmitGenerationJob) do
        post generations_path, params: { generation: { workflow_id: workflows(:sd_image).id, prompt: 'A fox',
                                                       aspect_ratio: '4:3' } }
      end
    end

    assert_redirected_to '/image'
    generation = users(:alice).generations.recent.first

    assert_predicate generation, :queued?
    assert_equal '4:3', generation.aspect_ratio
  end

  test 'creating with an uploaded image' do
    post generations_path, params: { generation: { workflow_id: workflows(:image_to_3d).id, input_image: png_upload } }

    assert_redirected_to '/3d'
    assert_predicate users(:alice).generations.recent.first.input_image, :attached?
  end

  test 'an invalid submission re-renders the form with the error and keeps the input' do
    assert_no_difference('Generation.count') do
      post generations_path, params: { generation: { workflow_id: workflows(:sd_image).id, prompt: '',
                                                     negative_prompt: 'keep me' } }
    end

    assert_response :unprocessable_content
    assert_select '.alert-danger', text: /Prompt can't be blank/
    assert_select 'textarea[name="generation[negative_prompt]"]', text: 'keep me'
    assert_no_enqueued_jobs(only: SubmitGenerationJob)
  end

  test 'a disabled workflow cannot be used' do
    post generations_path, params: { generation: { workflow_id: workflows(:retired_image).id, prompt: 'x' } }

    assert_response :unprocessable_content
  end

  test 'results lists only the user\'s own work' do
    get generations_path

    assert_response :success
    assert_select '.result-card', count: 3
    assert_select '.result-card', text: /Bob's secret project/, count: 0
  end

  test 'results can be filtered by kind and status' do
    get generations_path, params: { kind: 'video' }

    assert_select '.result-card', count: 1
    assert_select '.text-12', text: /1 filter active/

    get generations_path, params: { status: 'failed' }

    assert_select '.result-card', text: /A dancing robot/
    assert_select '.filter-chip.danger', text: /Failed/
  end

  test 'results ignores unknown filters' do
    get generations_path, params: { kind: 'hologram', status: 'exploded' }

    assert_select '.result-card', count: 3
  end

  test 'results paginates' do
    30.times { |i| users(:alice).generations.create!(workflow: workflows(:sd_image), prompt: "p#{i}") }

    get generations_path

    assert_select '.result-card', count: GenerationsController::PER_PAGE
    assert_select 'nav[aria-label=Pages]'
  end

  test 'shows a finished generation with its outputs' do
    generation = generations(:alice_done)
    generation.outputs.attach(io: file_fixture('pixel.png').open, filename: 'out.png', content_type: 'image/png')

    get generation_path(generation)

    assert_response :success
    assert_select 'h1', text: 'A lighthouse at dusk'
    assert_select 'img.output-media'
    assert_select 'a', text: /Download/
    assert_select 'button', text: /Run again/
    assert_select 'dd', text: '42'
    assert_select '.text-12', text: /Started processing/
    assert_select '.text-12', text: /Processing took/
  end

  test 'shows why a generation failed' do
    get generation_path(generations(:alice_failed))

    assert_select '.status-panel', text: /Value not in list/
  end

  test 'hides backend internals from non-admins' do
    get generation_path(generations(:alice_done))

    assert_select 'code', text: 'done-prompt', count: 0
  end

  test 'cannot see someone else\'s generation' do
    get generation_path(generations(:bob_done))

    assert_response :not_found
  end

  test 'run again queues a copy with the same settings' do
    original = generations(:alice_done)

    assert_enqueued_with(job: SubmitGenerationJob) { post retry_generation_path(original) }
    copy = users(:alice).generations.recent.first

    assert_redirected_to generation_path(copy)
    assert_equal original.prompt, copy.prompt
    assert_equal original.negative_prompt, copy.negative_prompt
    assert_not_equal original.id, copy.id
  end

  test 'run again reuses the input image' do
    original = users(:alice).generations.create!(workflow: workflows(:image_to_3d), input_image: png_upload)

    post retry_generation_path(original)

    assert_equal original.input_image.blob, users(:alice).generations.recent.first.input_image.blob
  end

  test 'deleting a generation' do
    assert_difference('Generation.count', -1) { delete generation_path(generations(:alice_done)) }
    assert_redirected_to generations_path
  end

  test 'cannot delete someone else\'s generation' do
    assert_no_difference('Generation.count') { delete generation_path(generations(:bob_done)) }
    assert_response :not_found
  end

  test 'cancelling a running generation' do
    generation = generations(:alice_running)
    backend = backends(:gpu)
    stub_request(:post, comfy_url(backend, 'queue')).with(body: { delete: ['running-prompt'] }.to_json)
    stub_request(:post, comfy_url(backend, 'interrupt')).with(body: { prompt_id: 'running-prompt' }.to_json)

    post cancel_generation_path(generation)

    assert_redirected_to queue_path
    assert_equal 'Cancelled.', flash[:notice]
    assert_predicate generation.reload, :failed?
    assert_equal 'Cancelled', generation.error_message
  end

  test 'cannot cancel someone else\'s generation' do
    sign_in_as users(:bob)

    post cancel_generation_path(generations(:alice_running))

    assert_response :not_found
    assert_predicate generations(:alice_running).reload, :running?
  end

  test 'admins can cancel anyone\'s generation' do
    sign_in_as users(:admin)
    generation = generations(:alice_running)
    backend = backends(:gpu)
    stub_request(:post, comfy_url(backend, 'queue')).with(body: { delete: ['running-prompt'] }.to_json)
    stub_request(:post, comfy_url(backend, 'interrupt')).with(body: { prompt_id: 'running-prompt' }.to_json)

    post cancel_generation_path(generation)

    assert_redirected_to queue_path
    assert_predicate generation.reload, :failed?
  end

  test 'the result page shows a cancel button while a job is running' do
    get generation_path(generations(:alice_running))

    assert_select 'button', text: /Cancel/
  end
end

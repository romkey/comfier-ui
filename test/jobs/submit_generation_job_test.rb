require 'test_helper'

class SubmitGenerationJobTest < ActiveJob::TestCase
  setup do
    @backend = backends(:gpu)
    @generation = users(:alice).generations.create!(workflow: workflows(:sd_image), prompt: 'A fox', seed: '11')
  end

  test 'submits the rendered workflow and starts polling' do
    submit = stub_request(:post, comfy_url(@backend, 'prompt'))
             .with { |req| JSON.parse(req.body).dig('prompt', '6', 'inputs', 'text') == 'A fox' }
             .to_return(body: { prompt_id: 'p-1' }.to_json)

    assert_enqueued_with(job: PollGenerationJob, args: [@generation]) do
      SubmitGenerationJob.perform_now(@generation)
    end

    assert_requested submit
    @generation.reload

    assert_predicate @generation, :running?
    assert_equal 'p-1', @generation.comfy_prompt_id
    assert_equal @backend, @generation.backend
    assert_not_nil @generation.submitted_at
  end

  test 'sends seeds and sizes as numbers' do
    stub_request(:post, comfy_url(@backend, 'prompt')).to_return(body: { prompt_id: 'p-1' }.to_json)

    SubmitGenerationJob.perform_now(@generation)

    assert_requested(:post, comfy_url(@backend, 'prompt')) do |req|
      inputs = JSON.parse(req.body).dig('prompt', '5', 'inputs')
      inputs['width'] == 512 && inputs['height'] == 512
    end
  end

  test 'uploads the input image first and references it in the workflow' do
    generation = users(:alice).generations.create!(workflow: workflows(:image_to_3d),
                                                   input_image: png_upload('chest.png'))
    stub_request(:post, comfy_url(@backend, 'upload/image'))
      .to_return(body: { name: "comfier-#{generation.id}-chest.png", subfolder: '', type: 'input' }.to_json)
    stub_request(:post, comfy_url(@backend, 'prompt')).to_return(body: { prompt_id: 'p-3d' }.to_json)

    SubmitGenerationJob.perform_now(generation)

    assert_requested(:post, comfy_url(@backend, 'prompt')) do |req|
      JSON.parse(req.body).dig('prompt', '1', 'inputs', 'image') == "comfier-#{generation.id}-chest.png"
    end
    generation.reload

    assert_predicate generation, :running?
    assert_equal "comfier-#{generation.id}-chest.png", generation.parameters['backend_input_image']
  end

  test 'fails with ComfyUI\'s explanation when the workflow is rejected' do
    stub_request(:post, comfy_url(@backend, 'prompt'))
      .to_return(status: 400, body: { error: { message: 'Prompt outputs failed validation' } }.to_json)

    assert_no_enqueued_jobs(only: PollGenerationJob) { SubmitGenerationJob.perform_now(@generation) }
    assert_predicate @generation.reload, :failed?
    assert_equal 'Prompt outputs failed validation', @generation.error_message
  end

  test 'fails when no backend is available' do
    @backend.update!(enabled: false)

    SubmitGenerationJob.perform_now(@generation)

    assert_predicate @generation.reload, :failed?
    assert_match(/No ComfyUI backend/, @generation.error_message)
  end

  test 'fails when the backend is unreachable' do
    stub_request(:post, comfy_url(@backend, 'prompt')).to_raise(Errno::ECONNREFUSED)

    SubmitGenerationJob.perform_now(@generation)

    assert_predicate @generation.reload, :failed?
  end

  test 'fails when the workflow was deleted' do
    @generation.workflow.destroy!

    SubmitGenerationJob.perform_now(@generation.reload)

    assert_predicate @generation.reload, :failed?
    assert_match(/workflow .* was removed/, @generation.error_message)
  end

  test 'does nothing for a generation that is already running' do
    SubmitGenerationJob.perform_now(generations(:alice_running))

    assert_not_requested :post, comfy_url(@backend, 'prompt')
  end
end

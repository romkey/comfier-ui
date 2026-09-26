require 'test_helper'

class GenerationCancellerTest < ActiveSupport::TestCase
  setup do
    @generation = generations(:alice_running)
    @backend = backends(:gpu)
  end

  test 'cancels a running generation on ComfyUI and marks it failed' do
    prompt_id = @generation.comfy_prompt_id
    queue = stub_request(:post, comfy_url(@backend, 'queue')).with(body: { delete: [prompt_id] }.to_json)
    interrupt = stub_request(:post, comfy_url(@backend, 'interrupt')).with(body: { prompt_id: }.to_json)

    assert GenerationCanceller.call(@generation).cancelled
    assert_predicate @generation.reload, :failed?
    assert_equal 'Cancelled', @generation.error_message
    assert_requested queue
    assert_requested interrupt
  end

  test 'cancels a queued generation without calling ComfyUI' do
    @generation.update!(status: :queued, backend: nil, comfy_prompt_id: nil, submitted_at: nil)

    assert GenerationCanceller.call(@generation).cancelled
    assert_predicate @generation.reload, :failed?
    assert_equal 'Cancelled', @generation.error_message
    assert_not_requested :post, %r{/queue}
    assert_not_requested :post, %r{/interrupt}
  end

  test 'still cancels locally when ComfyUI cannot be reached' do
    stub_request(:post, comfy_url(@backend, 'queue')).to_timeout
    stub_request(:post, comfy_url(@backend, 'interrupt')).to_timeout

    assert GenerationCanceller.call(@generation).cancelled
    assert_predicate @generation.reload, :failed?
    assert_equal 'Cancelled', @generation.error_message
  end

  test 'does nothing for a finished generation' do
    generation = generations(:alice_done)

    assert_not GenerationCanceller.call(generation).cancelled
    assert_predicate generation.reload, :succeeded?
  end
end

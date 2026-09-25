require 'test_helper'

class PollGenerationJobTest < ActiveJob::TestCase
  setup do
    @generation = generations(:alice_running)
    @backend = backends(:gpu)
    @history_url = comfy_url(@backend, 'history/running-prompt')
  end

  def stub_history(entry)
    body = entry ? { 'running-prompt' => entry } : {}
    stub_request(:get, @history_url).to_return(body: body.to_json)
    stub_request(:get, comfy_url(@backend, 'history')).with(query: { max_items: '64' }).to_return(body: body.to_json)
  end

  def stub_queue(running: [], pending: [])
    stub_request(:get, comfy_url(@backend, 'queue'))
      .to_return(body: { queue_running: running, queue_pending: pending }.to_json)
  end

  def success_entry(*files)
    started_ms = 1_700_000_000_000
    finished_ms = started_ms + 28_500
    { status: { status_str: 'success', completed: true,
                messages: [
                  ['execution_start', { 'timestamp' => started_ms }],
                  ['execution_success', { 'timestamp' => finished_ms }]
                ] },
      outputs: { '9' => { images: files.map { { filename: it, subfolder: '', type: 'output' } } } } }
  end

  test 'checks again later while ComfyUI is still working' do
    stub_history(nil)
    stub_queue(running: [[1, 'running-prompt']])

    assert_enqueued_with(job: PollGenerationJob, args: [@generation]) { PollGenerationJob.perform_now(@generation) }
    assert_predicate @generation.reload, :running?
  end

  test 'gives up after the timeout' do
    @generation.update!(submitted_at: 3.hours.ago)
    stub_history(nil)
    stub_queue(running: [[1, 'running-prompt']])

    assert_no_enqueued_jobs(only: PollGenerationJob) { PollGenerationJob.perform_now(@generation) }
    assert_predicate @generation.reload, :failed?
    assert_match(/Timed out/, @generation.error_message)
  end

  test 'keeps waiting through a dropped connection' do
    stub_request(:get, @history_url).to_timeout
    stub_request(:get, comfy_url(@backend, 'history')).with(query: { max_items: '64' }).to_timeout

    assert_enqueued_with(job: PollGenerationJob) { PollGenerationJob.perform_now(@generation) }
    assert_predicate @generation.reload, :running?
  end

  test 'fails when ComfyUI leaves the queue without history' do
    @generation.update!(submitted_at: 3.minutes.ago)
    stub_history(nil)
    stub_queue

    assert_no_enqueued_jobs(only: PollGenerationJob) { PollGenerationJob.perform_now(@generation) }

    assert_predicate @generation.reload, :failed?
    assert_match(/never received the result/, @generation.error_message)
  end

  test 'shares the result when share was requested at create time' do
    @generation.update!(share_when_done: true, share_prompt: true, share_input: false)
    stub_history(success_entry('comfier_00001_.png'))
    stub_request(:get, comfy_url(@backend, 'view')).with(query: hash_including({})).to_return(body: 'png')

    PollGenerationJob.perform_now(@generation)
    @generation.reload

    assert_predicate @generation, :succeeded?
    assert_predicate @generation, :shared?
    assert_predicate @generation, :share_prompt?
    assert_nil @generation.share_when_done
  end

  test 'downloads every output and marks the generation done' do
    stub_history(success_entry('comfier_00001_.png', 'comfier_00002_.png'))
    stub_queue
    stub_request(:get, comfy_url(@backend, 'view')).with(query: hash_including({})).to_return do |req|
      { body: "data for #{URI.decode_www_form(req.uri.query).to_h.fetch('filename')}" }
    end

    PollGenerationJob.perform_now(@generation)
    @generation.reload

    assert_predicate @generation, :succeeded?
    assert_not_nil @generation.completed_at
    assert_not_nil @generation.processing_started_at
    assert_not_nil @generation.processing_ended_at
    assert_in_delta 28.5, @generation.processing_seconds, 0.1
    assert_equal %w[comfier_00001_.png comfier_00002_.png], @generation.outputs.map { it.filename.to_s }.sort
    assert_equal 'image/png', @generation.outputs.first.content_type
    assert_equal 'data for comfier_00001_.png', @generation.outputs.min_by { it.filename.to_s }.download
  end

  test 'retries when a download fails partway' do
    stub_history(success_entry('a.png', 'b.png'))
    stub_queue
    stub_request(:get,
                 comfy_url(@backend, 'view')).with(query: hash_including('filename' => 'a.png')).to_return(body: 'A')
    stub_request(:get, comfy_url(@backend, 'view')).with(query: hash_including('filename' => 'b.png')).to_timeout

    assert_enqueued_with(job: PollGenerationJob) { PollGenerationJob.perform_now(@generation) }

    assert_predicate @generation.reload, :running?
    assert_not @generation.outputs.attached?
    assert_equal 1, @generation.parameters['download_attempts']
  end

  test 'fails after repeated download errors' do
    stub_history(success_entry('a.png'))
    stub_queue
    stub_request(:get, comfy_url(@backend, 'view')).with(query: hash_including({})).to_timeout
    @generation.update!(parameters: { download_attempts: PollGenerationJob::MAX_DOWNLOAD_ATTEMPTS - 1 })

    assert_no_enqueued_jobs(only: PollGenerationJob) { PollGenerationJob.perform_now(@generation) }

    assert_predicate @generation.reload, :failed?
    assert_match(/Couldn't download outputs/, @generation.error_message)
  end

  test 'fails with the ComfyUI error' do
    stub_history(status: { status_str: 'error',
                           messages: [
                             ['execution_start', { 'timestamp' => 1_700_000_000_000 }],
                             ['execution_error', { 'timestamp' => 1_700_000_005_000, 'node_type' => 'KSampler',
                                                   exception_message: 'OOM' }]
                           ] })

    PollGenerationJob.perform_now(@generation)

    assert_predicate @generation.reload, :failed?
    assert_equal 'KSampler: OOM', @generation.error_message
    assert_not_nil @generation.processing_started_at
    assert_not_nil @generation.processing_ended_at
  end

  test 'fails when the workflow saved nothing' do
    stub_history(status: { status_str: 'success' },
                 outputs: { '20' => { images: [{ filename: 'p.png', type: 'temp' }] } })

    PollGenerationJob.perform_now(@generation)

    assert_predicate @generation.reload, :failed?
    assert_match(/Save node/, @generation.error_message)
  end

  test 'fails when the backend was deleted' do
    @backend.destroy!

    PollGenerationJob.perform_now(@generation.reload)

    assert_predicate @generation.reload, :failed?
  end

  test 'does nothing once the generation is finished' do
    PollGenerationJob.perform_now(generations(:alice_done))

    assert_not_requested :get, comfy_url(@backend, 'history/done-prompt')
  end
end

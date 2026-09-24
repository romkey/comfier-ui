require 'test_helper'

class PollGenerationJobTest < ActiveJob::TestCase
  setup do
    @generation = generations(:alice_running)
    @backend = backends(:gpu)
    @history_url = comfy_url(@backend, 'history/running-prompt')
  end

  def stub_history(entry)
    stub_request(:get, @history_url).to_return(body: (entry ? { 'running-prompt' => entry } : {}).to_json)
  end

  def success_entry(*files)
    { status: { status_str: 'success', completed: true },
      outputs: { '9' => { images: files.map { { filename: it, subfolder: '', type: 'output' } } } } }
  end

  test 'checks again later while ComfyUI is still working' do
    stub_history(nil)

    assert_enqueued_with(job: PollGenerationJob, args: [@generation]) { PollGenerationJob.perform_now(@generation) }
    assert_predicate @generation.reload, :running?
  end

  test 'gives up after the timeout' do
    @generation.update!(submitted_at: 3.hours.ago)
    stub_history(nil)

    assert_no_enqueued_jobs(only: PollGenerationJob) { PollGenerationJob.perform_now(@generation) }
    assert_predicate @generation.reload, :failed?
    assert_match(/Timed out/, @generation.error_message)
  end

  test 'keeps waiting through a dropped connection' do
    stub_request(:get, @history_url).to_timeout

    assert_enqueued_with(job: PollGenerationJob) { PollGenerationJob.perform_now(@generation) }
    assert_predicate @generation.reload, :running?
  end

  test 'downloads every output and marks the generation done' do
    stub_history(success_entry('comfier_00001_.png', 'comfier_00002_.png'))
    stub_request(:get, comfy_url(@backend, 'view')).with(query: hash_including({})).to_return do |req|
      { body: "data for #{URI.decode_www_form(req.uri.query).to_h.fetch('filename')}" }
    end

    PollGenerationJob.perform_now(@generation)
    @generation.reload

    assert_predicate @generation, :succeeded?
    assert_not_nil @generation.completed_at
    assert_equal %w[comfier_00001_.png comfier_00002_.png], @generation.outputs.map { it.filename.to_s }.sort
    assert_equal 'image/png', @generation.outputs.first.content_type
    assert_equal 'data for comfier_00001_.png', @generation.outputs.min_by { it.filename.to_s }.download
  end

  test 'attaches nothing if a download fails partway' do
    stub_history(success_entry('a.png', 'b.png'))
    stub_request(:get,
                 comfy_url(@backend, 'view')).with(query: hash_including('filename' => 'a.png')).to_return(body: 'A')
    stub_request(:get, comfy_url(@backend, 'view')).with(query: hash_including('filename' => 'b.png')).to_timeout

    PollGenerationJob.perform_now(@generation)

    assert_predicate @generation.reload, :running?
    assert_not @generation.outputs.attached?
  end

  test 'fails with the ComfyUI error' do
    stub_history(status: { status_str: 'error',
                           messages: [['execution_error', { node_type: 'KSampler', exception_message: 'OOM' }]] })

    PollGenerationJob.perform_now(@generation)

    assert_predicate @generation.reload, :failed?
    assert_equal 'KSampler: OOM', @generation.error_message
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

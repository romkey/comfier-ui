require 'test_helper'

class PollModelDownloadJobTest < ActiveJob::TestCase
  setup do
    @backend = backends(:gpu)
    @download = @backend.model_downloads.create!(directory: 'checkpoints', name: 'sd15.safetensors',
                                                 url: 'https://hf.test/sd15.safetensors', status: :running,
                                                 via: :node, comfy_prompt_id: 'dl-1', started_at: Time.current)
  end

  def stub_history(entry)
    body = entry ? { 'dl-1' => entry } : {}
    stub_request(:get, comfy_url(@backend, 'history/dl-1')).to_return(body: body.to_json)
    stub_request(:get, comfy_url(@backend, 'history')).with(query: { max_items: '64' }).to_return(body: body.to_json)
  end

  test 'keeps polling while the node is still running' do
    stub_history(nil)

    assert_enqueued_with(job: PollModelDownloadJob, args: [@download]) { PollModelDownloadJob.perform_now(@download) }
    assert_predicate @download.reload, :running?
  end

  test 'succeeds once the file shows up on the backend' do
    stub_history({ 'status' => { 'status_str' => 'success' }, 'outputs' => {} })
    stub_inventory(@backend, { checkpoints: ['sd15.safetensors'] }, downloader: true)

    PollModelDownloadJob.perform_now(@download)

    assert_predicate @download.reload, :succeeded?
    assert_includes @backend.reload.model_inventory['checkpoints'], 'sd15.safetensors'
  end

  test 'fails if the node finished but the file is not there' do
    stub_history({ 'status' => { 'status_str' => 'success' }, 'outputs' => {} })
    stub_inventory(@backend, { checkpoints: [] }, downloader: true)

    PollModelDownloadJob.perform_now(@download)

    assert_predicate @download.reload, :failed?
    assert_match(/isn't there/, @download.error_message)
  end

  test 'fails with the node’s error' do
    stub_history({ 'status' => { 'status_str' => 'error', 'messages' => [
                   ['execution_error', { 'node_type' => 'ComfierModelDownload', 'exception_message' => 'HTTP 401' }]
                 ] } })

    PollModelDownloadJob.perform_now(@download)

    assert_equal 'ComfierModelDownload: HTTP 401', @download.reload.error_message
  end

  test 'waits for Manager’s queue to drain' do
    @download.update!(via: :manager, comfy_prompt_id: nil)
    stub_request(:get, comfy_url(@backend, 'v2/manager/queue/status'))
      .to_return(body: { is_processing: true, in_progress_count: 1 }.to_json)

    assert_enqueued_with(job: PollModelDownloadJob) { PollModelDownloadJob.perform_now(@download) }
    assert_predicate @download.reload, :running?
  end

  test 'rides out a backend that is briefly unreachable' do
    stub_request(:get, comfy_url(@backend, 'history/dl-1')).to_raise(Errno::ECONNREFUSED)

    assert_enqueued_with(job: PollModelDownloadJob) { PollModelDownloadJob.perform_now(@download) }
    assert_predicate @download.reload, :running?
  end

  test 'gives up after the timeout' do
    @download.update!(started_at: 13.hours.ago)
    stub_history(nil)

    assert_no_enqueued_jobs(only: PollModelDownloadJob) { PollModelDownloadJob.perform_now(@download) }
    assert_match(/Timed out/, @download.reload.error_message)
  end
end

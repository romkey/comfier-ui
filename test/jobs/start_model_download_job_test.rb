require 'test_helper'

class StartModelDownloadJobTest < ActiveJob::TestCase
  NODE = Comfyui::Client::DOWNLOADER_NODE

  setup do
    @backend = backends(:gpu)
    @download = @backend.model_downloads.create!(directory: 'checkpoints', name: 'sd15.safetensors',
                                                 url: 'https://hf.test/sd15.safetensors')
  end

  def stub_node(present)
    stub_request(:get,
                 comfy_url(@backend, "object_info/#{NODE}")).to_return(body: (present ? { NODE => {} } : {}).to_json)
  end

  def stub_manager(version = '4.2.2', catalog: [])
    stub_request(:get,
                 comfy_url(@backend, 'v2/manager/version')).to_return(version ? { body: version } : { status: 404 })
    stub_request(:get,
                 comfy_url(@backend,
                           'v2/externalmodel/getlist?mode=cache')).to_return(body: { models: catalog }.to_json)
  end

  test 'runs the downloader node as a one-node workflow and starts polling' do
    stub_node(true)
    submit = stub_request(:post, comfy_url(@backend, 'prompt'))
             .with { |req| JSON.parse(req.body)['prompt'] == @download.downloader_graph }
             .to_return(body: { prompt_id: 'dl-1' }.to_json)

    assert_enqueued_with(job: PollModelDownloadJob, args: [@download]) { StartModelDownloadJob.perform_now(@download) }

    assert_requested submit
    @download.reload

    assert_predicate @download, :running?
    assert_predicate @download, :node?
    assert_equal 'dl-1', @download.comfy_prompt_id
  end

  test 'falls back to ComfyUI-Manager for an exact catalog match' do
    stub_node(false)
    entry = { 'name' => 'SD1.5', 'filename' => 'sd15.safetensors', 'save_path' => 'checkpoints', 'base' => 'SD1.5',
              'url' => 'https://hf.test/sd15.safetensors', 'installed' => 'False', 'description' => 'long' }
    stub_manager(catalog: [entry.merge('save_path' => 'checkpoints/SD1.5'), entry])
    install = stub_request(:post, comfy_url(@backend, 'v2/manager/queue/install_model'))
              .with do |req|
      JSON.parse(req.body) == entry.except('installed',
                                           'description').merge('ui_id' => "comfier-#{@download.id}")
    end
    start = stub_request(:post, comfy_url(@backend, 'v2/manager/queue/start'))

    StartModelDownloadJob.perform_now(@download)

    assert_requested install
    assert_requested start
    assert_predicate @download.reload, :manager?
    assert_predicate @download, :running?
  end

  test 'explains when Manager has no catalog entry for the file' do
    stub_node(false)
    stub_manager(catalog: [{ 'filename' => 'sd15.safetensors', 'save_path' => 'checkpoints/SD1.5' }])

    assert_no_enqueued_jobs(only: PollModelDownloadJob) { StartModelDownloadJob.perform_now(@download) }
    assert_predicate @download.reload, :failed?
    assert_match(/only downloads models from its catalog/, @download.error_message)
  end

  test 'explains how to let Manager download when its security settings refuse' do
    stub_node(false)
    stub_manager(catalog: [{ 'filename' => 'sd15.safetensors', 'save_path' => 'checkpoints' }])
    stub_request(:post, comfy_url(@backend, 'v2/manager/queue/install_model')).to_return(status: 403)

    StartModelDownloadJob.perform_now(@download)

    assert_match(/network_mode = personal_cloud/, @download.reload.error_message)
  end

  test 'explains what to install when the backend cannot download at all' do
    stub_node(false)
    stub_manager(nil)

    StartModelDownloadJob.perform_now(@download)

    assert_predicate @download.reload, :failed?
    assert_match(/Install the Comfier downloader node on GPU box/, @download.error_message)
  end

  test 'fails with the reason when the backend is unreachable' do
    stub_request(:get, comfy_url(@backend, "object_info/#{NODE}")).to_raise(Errno::ECONNREFUSED)

    StartModelDownloadJob.perform_now(@download)

    assert_match(/Couldn't reach GPU box/, @download.reload.error_message)
  end

  test 'leaves downloads that already started alone' do
    @download.update!(status: :running)

    StartModelDownloadJob.perform_now(@download)

    assert_not_requested :get, comfy_url(@backend, "object_info/#{NODE}")
  end
end

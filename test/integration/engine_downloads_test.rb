require 'test_helper'

# Downloading mflux and MLX video models onto a Mac from its server page, ahead of the first job.
class EngineDownloadsTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @mac = create_agent_backend!(owner: @alice, name: 'Mac Studio')
    @socket = bring_mac_online!(@mac, engines: { mflux: { models: [] } })
    @workflow = engine_workflow!
    Agent::Availability.store!(@workflow, @mac)
    sign_in_as @alice
  end

  test "the server's styles offer a style's model for download while it still runs" do
    get server_styles_path(@mac)

    assert_select "##{ActionView::RecordIdentifier.dom_id(@workflow, :server_style)}" do
      assert_select "form[action*='workflow_id=#{@workflow.id}'] button", text: 'Download'
      assert_select '.text-warning', text: /isn't downloaded/
    end
  end

  test 'requesting the download sends the engine and model to the server' do
    assert_difference('ModelDownload.count', 1) { post server_downloads_path(@mac, workflow_id: @workflow.id) }

    download = ModelDownload.last

    assert_equal ['mflux', 'z-image-turbo', 'mflux', nil],
                 [download.engine, download.name, download.directory, download.url]
    message = @socket.last_of_type('model.download')

    assert_equal({ 'type' => 'model.download', 'download_id' => download.agent_download_id, 'engine' => 'mflux',
                   'model' => 'z-image-turbo' }, message)
  end

  test 'asking twice reuses the download in progress' do
    2.times { post server_downloads_path(@mac, workflow_id: @workflow.id) }

    assert_equal 1, ModelDownload.where(engine: 'mflux').count
  end

  test 'download all includes engine models' do
    post server_downloads_path(@mac, all: true)

    assert ModelDownload.exists?(backend: @mac, engine: 'mflux', name: 'z-image-turbo')
  end

  test 'progress without a total, then completion, leaves the style with nothing to download' do
    post server_downloads_path(@mac, workflow_id: @workflow.id)
    download = ModelDownload.last
    agent_message(@mac, { 'type' => 'model.download.progress', 'download_id' => download.agent_download_id,
                          'state' => 'downloading', 'bytes_done' => 2.gigabytes })
    get server_downloads_path(@mac)

    assert_select 'div', text: %r{mflux/z-image-turbo}
    assert_select '.text-secondary', text: /2 GB so far/

    agent_message(@mac, { 'type' => 'model.download.completed', 'download_id' => download.agent_download_id,
                          'folder' => 'mflux', 'filename' => 'z-image-turbo', 'bytes' => 8.gigabytes })

    assert_equal 'completed', download.reload.agent_state
    assert_empty Agent::Availability.compute(@workflow, @mac.reload).models
  end

  test 'an engine download failure reads as a sentence with the reason' do
    post server_downloads_path(@mac, workflow_id: @workflow.id)
    download = ModelDownload.last
    agent_message(@mac, { 'type' => 'model.download.failed', 'download_id' => download.agent_download_id,
                          'reason' => 'engine', 'detail' => 'ConnectError: no route' })

    assert_equal "Mac Studio couldn't download z-image-turbo. ConnectError: no route", download.reload.error_message
  end

  test 'an MLX video style whose recipe names a model rather than a repo offers nothing to download' do
    video = Workflow.new(name: 'Bad LTX', kind: 'video', engine: 'mlx_video',
                         graph: { 'command' => 'mlx_video.ltx_2.generate', 'model' => 'z-image-turbo',
                                  'prompt' => '{{prompt}}' })
    video.save!(validate: false) # saved before recipes were checked for this

    assert_nil video.recipe_model
    assert_empty Agent::Availability.compute(video, @mac.reload).models
  end
end

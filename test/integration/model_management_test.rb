require 'test_helper'

# Deleting models from a server, reloading them (delete, then download again), and cancelling every download.
class ModelManagementTest < ActionDispatch::IntegrationTest
  CHECKPOINT = 'v1-5-pruned-emaonly-fp16.safetensors'.freeze

  setup do
    @alice = users(:alice)
    @workflow = workflows(:sd_image)
    backends(:gpu).update!(enabled: false)
    set_model_links(@workflow, url: 'https://huggingface.co/x/sd15.safetensors', bytes: 2.gigabytes)
    @backend = create_agent_backend!(owner: @alice)
    @socket = bring_online_for!(@backend, @workflow)
    sign_in_as @alice
  end

  def deletes = @socket.of_type('model.delete')

  def queued_download!(name, state: 'queued')
    @backend.model_downloads.create!(directory: 'checkpoints', name:, url: "https://huggingface.co/x/#{name}",
                                     via: :agent, agent_state: state, agent_download_id: "d_#{SecureRandom.hex(4)}",
                                     status: state == 'queued' ? :queued : :running)
  end

  test "deleting a workflow's models sends a delete for each file the server has" do
    delete server_models_path(@backend, workflow_id: @workflow.id)

    assert_redirected_to server_path(@backend)
    assert_equal([{ 'folder' => 'checkpoints', 'filename' => CHECKPOINT }],
                 deletes.map { it.slice('folder', 'filename') })
    assert ActivityLog.exists?(kind: 'model_delete_requested', subject: @backend)
  end

  test 'a model another workflow uses is deleted anyway' do
    other = Workflow.create!(name: 'SD copy', kind: 'image', graph_json: @workflow.graph.to_json)
    Agent::Requirements.for(other)

    delete server_models_path(@backend, workflow_id: other.id)

    assert_equal [CHECKPOINT], deletes.pluck('filename')
  end

  test 'reloading deletes, then downloads again' do
    post reload_server_models_path(@backend, workflow_id: @workflow.id)

    types = @socket.sent.pluck('type')

    assert_operator types.index('model.delete'), :<, types.index('model.download')
    download = @socket.last_of_type('model.download')

    assert_equal ['checkpoints', CHECKPOINT, false], download.values_at('folder', 'filename', 'overwrite')
    assert_match(/Deleting 1 model and queued 1 download/, flash[:notice])
  end

  test 'a download of the file being deleted is cancelled first' do
    running = queued_download!(CHECKPOINT, state: 'downloading')

    delete server_models_path(@backend, workflow_id: @workflow.id)

    assert_equal 'cancelling', running.reload.agent_state
    assert_equal running.agent_download_id, @socket.last_of_type('model.download.cancel')['download_id']
  end

  test 'reloading a file that is already downloading keeps that download' do
    running = queued_download!(CHECKPOINT, state: 'downloading')

    post reload_server_models_path(@backend, workflow_id: @workflow.id)

    assert_empty deletes
    assert_equal 'downloading', running.reload.agent_state
    assert_equal [running], @backend.model_downloads.to_a
  end

  test "the server's reply removes the file, and a failure shows in the downloads log" do
    agent_message(@backend, { 'type' => 'model.deleted', 'delete_id' => 'x_1', 'folder' => 'checkpoints',
                              'filename' => CHECKPOINT, 'bytes' => 2.gigabytes })

    assert_not @backend.backend_models.exists?(filename: CHECKPOINT)

    agent_message(@backend, { 'type' => 'model.delete.failed', 'delete_id' => 'x_2', 'folder' => 'vae',
                              'filename' => 'ae.safetensors', 'reason' => 'error', 'detail' => 'Permission denied' })
    get server_downloads_path(@backend)

    assert_select '.status-panel', text: %r{Couldn't delete vae/ae.safetensors: Permission denied}
    delete clear_server_downloads_path(@backend)

    assert_empty Agent::ModelDeleter.failures(@backend)
  end

  test 'files picked from the inventory are deleted or reloaded' do
    delete server_models_path(@backend),
           params: { files: ["checkpoints/#{CHECKPOINT}", 'checkpoints/missing.safetensors'] }

    assert_equal [CHECKPOINT], deletes.pluck('filename')

    post reload_server_models_path(@backend), params: { files: ["checkpoints/#{CHECKPOINT}"] }

    assert_equal CHECKPOINT, @socket.last_of_type('model.download')['filename']
  end

  FP8 = 'sd15_fp8_scaled.safetensors'.freeze

  def fp8_workflow!(name, **links)
    workflow = Workflow.create!(name:, kind: 'image', graph_json: @workflow.graph.to_json.sub(CHECKPOINT, FP8))
    set_model_links(workflow, url: "https://huggingface.co/x/#{FP8}", bytes: 2.gigabytes, **links)
    workflow
  end

  # A Mac with the given checkpoints on disk; returns its socket.
  def mac_with!(*workflows, files:)
    @mac = create_agent_backend!(owner: @alice, name: 'Mac Studio')
    socket = connect_agent!(@mac)
    agent_hello(@mac, system: { devices: [{ name: 'Apple M3 Max', type: 'mps' }] })
    agent_inventory(@mac, **inventory_for(*workflows), models: { 'checkpoints' => files })
    agent_status(@mac)
    socket
  end

  test "a Mac's fp16 copy picked from the inventory is reloaded as a fresh stand-in" do
    socket = mac_with!(fp8_workflow!('SD fp8'), files: ['sd15_fp16.safetensors'])

    post reload_server_models_path(@mac), params: { files: ['checkpoints/sd15_fp16.safetensors'] }

    assert_equal ['sd15_fp16.safetensors'], socket.of_type('model.delete').pluck('filename')
    download = socket.last_of_type('model.download')

    assert_equal ['sd15_fp16_from_fp8.safetensors', 'fp8_to_fp16'], download&.values_at('filename', 'convert')
  end

  test "a picked file a workflow downloads by its own name doesn't also bring another's stand-in" do
    official = fp8_workflow!('SD fp8', fp16_url: 'https://huggingface.co/x/sd15_fp16.safetensors')
    socket = mac_with!(official, fp8_workflow!('SD fp8 too'), files: ['sd15_fp16.safetensors'])

    post reload_server_models_path(@mac), params: { files: ['checkpoints/sd15_fp16.safetensors'] }

    assert_equal ['sd15_fp16.safetensors'], socket.of_type('model.delete').pluck('filename')
    assert_equal [['sd15_fp16.safetensors', nil]], @mac.model_downloads.pluck(:name, :convert)
  end

  test 'every workflow on the server at once' do
    post reload_server_models_path(@backend, all: true)

    assert_equal [CHECKPOINT], deletes.pluck('filename')
    assert_equal [CHECKPOINT], @socket.of_type('model.download').pluck('filename')
  end

  test 'cancel all stops every download in progress or waiting' do
    running = queued_download!('a.safetensors', state: 'downloading')
    waiting = queued_download!('b.safetensors')

    delete cancel_all_server_downloads_path(@backend)

    assert_equal %w[cancelling cancelled], [running.reload.agent_state, waiting.reload.agent_state]
    assert_equal [running.agent_download_id], @socket.of_type('model.download.cancel').pluck('download_id')
    assert_equal 'Cancelling 2 downloads.', flash[:notice]
  end

  test "an older agent can't delete, and nothing is sent" do
    @backend.update!(agent_version: '0.4.14')

    delete server_models_path(@backend, workflow_id: @workflow.id)

    assert_match(/needs agent 0.4.15/, flash[:alert])
    assert_empty deletes
  end

  test "other people can't delete a server's models" do
    sign_in_as users(:bob)
    delete server_models_path(@backend, workflow_id: @workflow.id)

    assert_response :not_found
    assert_empty deletes
  end

  test 'the server page offers the actions' do
    get server_path(@backend)

    assert_select "form[action='#{reload_server_models_path(@backend)}'] input[name=all]"
    assert_select "input[type=checkbox][name='files[]'][value='checkpoints/#{CHECKPOINT}']"
    get server_styles_path(@backend)

    assert_select "##{ActionView::RecordIdentifier.dom_id(@workflow, :server_style)} button", text: 'Delete models'
  end

  test 'mflux models are deleted from the engine by name' do
    mac = create_agent_backend!(owner: @alice, name: 'Mac Studio')
    socket = bring_mac_online!(mac, engines: { mflux: { models: ['z-image-turbo'] } })
    workflow = engine_workflow!

    delete server_models_path(mac, workflow_id: workflow.id)

    assert_equal([{ 'engine' => 'mflux', 'model' => 'z-image-turbo' }],
                 socket.of_type('model.delete').map { it.slice('engine', 'model', 'folder') })

    agent_message(mac, { 'type' => 'model.deleted', 'delete_id' => 'x_1', 'engine' => 'mflux',
                         'model' => 'z-image-turbo', 'bytes' => 1.gigabyte })

    assert_empty mac.reload.engine_models('mflux')
  end

  test 'admins delete or reload a workflow on every server' do
    sign_in_as users(:admin)
    post reload_models_admin_workflow_path(@workflow)

    assert_redirected_to requirements_admin_workflow_path(@workflow)
    assert_equal [CHECKPOINT], deletes.pluck('filename')
    assert_equal 1, @socket.of_type('model.download').size

    post delete_models_admin_workflow_path(@workflow)

    assert_equal 2, deletes.size
    get requirements_admin_workflow_path(@workflow)

    assert_select "button[formaction='#{server_models_path(@backend, workflow_id: @workflow.id)}']",
                  text: 'Delete models'
  end
end

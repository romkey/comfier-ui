require 'test_helper'

class BackendTest < ActiveSupport::TestCase
  test 'normalizes the base URL' do
    backend = Backend.new(name: 'New', base_url: '  http://gpu.test:8188/  ')

    assert_equal 'http://gpu.test:8188', backend.base_url
  end

  test 'requires an http or https URL' do
    assert_predicate Backend.new(name: 'A', base_url: 'https://comfy.example.com/proxy'), :valid?
    assert_not Backend.new(name: 'B', base_url: 'ftp://comfy.example.com').valid?
    assert_not Backend.new(name: 'C', base_url: 'not a url').valid?
    assert_not Backend.new(name: 'D', base_url: '').valid?
  end

  test 'names are unique regardless of case' do
    assert_not Backend.new(name: 'gpu BOX', base_url: 'http://x.test').valid?
  end

  test 'auth token is encrypted at rest and blank tokens become nil' do
    backend = Backend.create!(name: 'Secure', base_url: 'http://secure.test', auth_token: 's3cret')
    raw = Backend.connection.select_value("SELECT auth_token FROM backends WHERE id = #{backend.id}")

    assert_not_includes raw, 's3cret'
    assert_equal 's3cret', backend.reload.auth_token
    backend.update!(auth_token: '   ')

    assert_nil backend.reload.auth_token
  end

  test 'check! records a healthy server' do
    backend = backends(:gpu)
    stub_request(:get, comfy_url(backend, 'system_stats')).to_return(
      body: { system: { comfyui_version: '0.3.62' }, devices: [{ name: 'cuda:0 NVIDIA RTX 5090' }] }.to_json
    )
    stub_inventory(backend, { checkpoints: ['v1-5-pruned-emaonly-fp16.safetensors'] }, downloader: true)

    assert backend.check!
    assert backend.last_check_ok
    assert_equal 'ComfyUI 0.3.62 · cuda:0 NVIDIA RTX 5090', backend.last_check_message
    assert_equal ['v1-5-pruned-emaonly-fp16.safetensors'], backend.model_inventory['checkpoints']
    assert_predicate backend, :downloader_available?
  end

  test 'refresh_inventory! records folder listings, keeping folders it was not asked about' do
    backend = backends(:gpu)
    backend.update!(model_inventory: { 'loras' => ['old.safetensors'] })
    stub_inventory(backend, { vae: ['sub\\ae.safetensors'] }, manager: '4.2.2')

    assert backend.refresh_inventory!(%w[vae])
    assert_equal({ 'loras' => ['old.safetensors'], 'vae' => ['sub/ae.safetensors'] }, backend.model_inventory)
    assert_equal '4.2.2', backend.manager_version
    assert_not backend.downloader_available?
    assert_predicate backend, :can_download_models?
    assert_not_nil backend.inventory_checked_at
  end

  test 'refresh_inventory! remembers what Manager can install when there is no downloader node' do
    backend = backends(:gpu)
    catalog = [{ 'filename' => 'sd15.safetensors', 'save_path' => 'checkpoints', 'url' => 'https://hf.test/sd15' },
               { 'filename' => 'odd.safetensors', 'save_path' => 'checkpoints/SD1.5', 'url' => 'https://hf.test/odd' }]
    stub_inventory(backend, { checkpoints: [] }, manager: '4.2.2', catalog:)

    backend.refresh_inventory!(%w[checkpoints])

    assert_equal({ 'checkpoints/sd15.safetensors' => 'https://hf.test/sd15',
                   'checkpoints/SD1.5/odd.safetensors' => 'https://hf.test/odd' }, backend.manager_catalog)

    stub_inventory(backend, { checkpoints: [] }, downloader: true, manager: '4.2.2', catalog:)
    backend.refresh_inventory!(%w[checkpoints])

    assert_empty backend.manager_catalog
  end

  test 'download_route prefers the node, and Manager only has its catalog' do
    backend = backends(:gpu)
    linked = ModelRequirement.parse_line('checkpoints/sd15.safetensors https://hf.test/sd15')
    unlinked = ModelRequirement.parse_line('checkpoints/other.safetensors')

    assert_nil backend.download_route(linked)
    assert_match(/can't download models/, backend.download_blocker)

    backend.assign_attributes(manager_version: '4.2.2', manager_catalog: { 'checkpoints/other.safetensors' => 'x' })

    assert_nil backend.download_route(linked)
    assert_equal :manager, backend.download_route(unlinked)
    assert_match(/Not in ComfyUI-Manager's catalog/, backend.download_blocker)

    backend.downloader_available = true

    assert_equal :node, backend.download_route(linked)
    assert_nil backend.download_route(unlinked)
    assert_match(/No download link/, backend.download_blocker)
  end

  test 'refresh_inventory! treats folders the server lacks as empty' do
    backend = backends(:gpu)
    stub_inventory(backend)
    stub_request(:get, comfy_url(backend, 'models/audio_encoders')).to_return(status: 404)

    assert backend.refresh_inventory!(%w[audio_encoders])
    assert_equal [], backend.model_inventory['audio_encoders']
    assert_not backend.can_download_models?
  end

  test 'refresh_inventory! returns false and keeps the old listing when the server is down' do
    backend = backends(:gpu)
    backend.update!(model_inventory: { 'vae' => ['ae.safetensors'] })
    stub_request(:get, comfy_url(backend, 'models/vae')).to_raise(Errno::ECONNREFUSED)

    assert_not backend.refresh_inventory!(%w[vae])
    assert_equal({ 'vae' => ['ae.safetensors'] }, backend.reload.model_inventory)
  end

  test 'model status is unknown until the folder has been listed' do
    backend = backends(:gpu)
    backend.model_inventory = { 'checkpoints' => ['v1-5-pruned-emaonly-fp16.safetensors'] }
    have = ModelRequirement.new(directory: 'checkpoints', name: 'v1-5-pruned-emaonly-fp16.safetensors')
    lack = ModelRequirement.new(directory: 'checkpoints', name: 'sdxl.safetensors')

    assert_equal :installed, backend.model_status(have)
    assert_equal :missing, backend.model_status(lack)
    assert_equal :unknown, backend.model_status(ModelRequirement.new(directory: 'vae', name: 'ae.safetensors'))
  end

  test 'missing_models lists what a workflow needs that the server lacks' do
    backend = backends(:gpu)
    workflow = workflows(:sd_image)

    backend.model_inventory = { 'checkpoints' => [] }

    assert_equal ['v1-5-pruned-emaonly-fp16.safetensors'], backend.missing_models(workflow).map(&:name)
    backend.model_inventory = { 'checkpoints' => ['v1-5-pruned-emaonly-fp16.safetensors'] }

    assert_empty backend.missing_models(workflow)
  end

  test 'check! records an unreachable server' do
    backend = backends(:gpu)
    stub_request(:get, comfy_url(backend, 'system_stats')).to_raise(Errno::ECONNREFUSED)

    assert_not backend.check!
    assert_predicate backend, :unhealthy?
    assert_match(/Couldn't reach GPU box/, backend.last_check_message)
  end

  test 'deleting a backend keeps generations and clears preferences' do
    backend = backends(:gpu)
    users(:alice).update!(preferred_backend: backend)
    backend.destroy!

    assert_nil generations(:alice_done).reload.backend
    assert_nil users(:alice).reload.preferred_backend
  end
end

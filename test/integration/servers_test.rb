require 'test_helper'

class ServersTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @admin = users(:admin)
  end

  def register!(name: 'Studio PC', **attrs)
    post servers_path, params: { backend: { name:, visibility: 'private' }.merge(attrs) }
  end

  test 'adding a server shows its key once and stores only a digest' do
    sign_in_as @alice
    register!

    assert_response :created
    backend = Backend.agent.find_by!(name: 'Studio PC')
    key = response.body[/cmf_[0-9A-Za-z]{43}/]

    assert key, 'the new key is on the setup page'
    assert_equal Digest::SHA256.hexdigest(key), backend.backend_keys.first.key_hash
    assert_equal @alice, backend.owner_user
    assert ActivityLog.exists?(kind: 'server_registered')

    get setup_server_path(backend)

    assert_response :success
    assert_no_match key, response.body
  end

  test 'the setup page shows how to install the agent on a Mac with the new key' do
    sign_in_as @alice
    register!

    key = response.body[/cmf_[0-9A-Za-z]{43}/]

    assert_select 'pre', text: %r{comfier-agent setup --url http://\S+ --key #{key} --allow-insecure}
    assert_select 'pre', text: /comfier-agent service install/
  end

  test 'registration can be turned off' do
    AppSetting.current.update!(allow_user_backends: false)
    sign_in_as @alice
    register!

    assert_response :forbidden
  end

  test 'admins turn member registration off in settings' do
    sign_in_as users(:admin)
    patch admin_app_setting_path, params: { app_setting: { allow_user_backends: '0' } }

    assert_not AppSetting.current.reload.allow_user_backends?
  end

  test 'private servers are hidden from other users' do
    backend = create_agent_backend!(owner: @alice)
    sign_in_as @bob

    get server_path(backend)

    assert_response :not_found

    get servers_path

    assert_no_match 'Agent box', response.body
  end

  test 'saving server settings shows only the success notice when share emails are fine' do
    backend = create_agent_backend!(owner: @alice, name: 'Studio PC')
    sign_in_as @alice
    patch server_path(backend), params: { backend: { name: 'Renamed PC', share_emails: '' } }

    follow_redirect!

    assert_response :success
    assert_select '.alert.alert-success', text: 'Saved.'
    assert_select '.alert.alert-danger', count: 0
  end

  test 'sharing by email lets that user see and use the server, but not manage it' do
    backend = create_agent_backend!(owner: @alice)
    sign_in_as @alice
    patch server_path(backend), params: { backend: { visibility: 'shared', share_emails: @bob.email } }

    assert_redirected_to settings_server_path(backend)
    assert_equal [@bob], backend.reload.shared_users.to_a

    sign_in_as @bob
    get server_path(backend)

    assert_response :success
    get settings_server_path(backend)

    assert_response :not_found
  end

  test 'other users see anonymized queue entries on a public server' do
    backend = create_agent_backend!(owner: @alice, visibility: 'public')
    Generation.create!(user: @alice, workflow: workflows(:sd_image), prompt: 'secret lighthouse', kind: :image,
                       status: :queued, backend:, agent_state: 'queued', filled_workflow_json: {})
    sign_in_as @bob
    get server_path(backend)

    assert_response :success
    assert_no_match 'secret lighthouse', response.body
  end

  test 'owners can pause, which tells the agent' do
    backend = create_agent_backend!(owner: @alice)
    socket = connect_agent!(backend)
    sign_in_as @alice
    post pause_server_path(backend)

    assert_predicate backend.reload, :paused?
    assert socket.last_of_type('config.pause')
  end

  test 'owners can re-scan styles in place and the agent is asked to refresh inventory' do
    backend = create_agent_backend!(owner: @alice)
    bring_online_for!(backend, workflows(:sd_image))
    socket = connect_agent!(backend)
    sign_in_as @alice

    post rescan_server_styles_path(backend), headers: { 'Turbo-Frame' => "server_styles_#{backend.id}" }

    assert_response :success
    assert_match 'Re-scanning', response.body
    assert_select "turbo-frame#server_styles_#{backend.id}" do |frames|
      assert_predicate frames, :one?
      assert_nil frames.first['src']
    end
    assert socket.last_of_type('inventory.refresh')
  end

  test 'styles frame responses omit src but the server page frame keeps it for reload' do
    backend = create_agent_backend!(owner: @alice)
    sign_in_as @alice

    get server_styles_path(backend), headers: { 'Turbo-Frame' => "server_styles_#{backend.id}" }

    assert_response :success
    assert_select "turbo-frame#server_styles_#{backend.id}" do |frames|
      assert_predicate frames, :one?
      assert_nil frames.first['src']
    end

    get server_path(backend)

    assert_select "turbo-frame#server_styles_#{backend.id}[src=?]", server_styles_path(backend)
  end

  test 'rotating shows a new key, revoking disconnects the agent' do
    backend = create_agent_backend!(owner: @alice)
    backend.issue_agent_key!
    socket = connect_agent!(backend)
    sign_in_as @alice

    post rotate_server_keys_path(backend)

    assert_response :created
    assert_match(/cmf_[0-9A-Za-z]{43}/, response.body)
    assert_equal 2, backend.backend_keys.active.count

    delete server_key_path(backend, backend.backend_keys.order(:created_at).first)

    assert_equal 4401, socket.close_code
  end

  test 'deleting a server keeps its history and closes its connection' do
    backend = create_agent_backend!(owner: @alice)
    backend.issue_agent_key!
    socket = connect_agent!(backend)
    sign_in_as @alice
    delete server_path(backend)

    assert_predicate backend.reload.deleted_at, :present?
    assert_equal 4401, socket.close_code
    assert_predicate backend.backend_keys.active, :none?
  end

  test 'server page title keeps apostrophes in the document title' do
    backend = create_agent_backend!(owner: @alice, name: "romkey's Mac Mini")
    sign_in_as @alice

    get server_path(backend)

    assert_response :success
    assert_match %r{<title>romkey's Mac Mini · Comfier</title>}, response.body
  end

  test 'the server page and chart data load for owners' do
    backend = create_agent_backend!(owner: @alice)
    bring_online_for!(backend, workflows(:sd_image))
    sign_in_as @alice

    get server_path(backend)

    assert_response :success
    assert_select "#server_presence_#{backend.id}"
    assert_select '[data-controller~="chart"]'

    get load_server_path(backend, range: 'week', format: :json)

    assert_response :success
    assert response.parsed_body.key?('utilization')
  end

  test 'owners can clear finished downloads from the log' do
    backend = create_agent_backend!(owner: @alice)
    backend.model_downloads.create!(directory: 'checkpoints', name: 'done.safetensors', url: 'https://hf.test/done',
                                    via: :agent, agent_state: 'completed', status: :succeeded)
    backend.model_downloads.create!(directory: 'checkpoints', name: 'active.safetensors', url: 'https://hf.test/active',
                                    via: :agent, agent_state: 'downloading', status: :running)
    sign_in_as @alice

    delete clear_server_downloads_path(backend)

    assert_redirected_to server_path(backend)
    assert_equal 1, backend.model_downloads.count
    assert_equal 'downloading', backend.model_downloads.sole.agent_state
  end

  test 'download tokens are write-only' do
    sign_in_as @alice
    post source_credentials_path, params: { source_credential: { host: 'huggingface.co', secret: 'hf_secret1234' } }
    follow_redirect!

    assert_match '1234', response.body
    assert_no_match 'hf_secret1234', response.body
    assert_equal 'hf_secret1234', @alice.source_credentials.first.secret
  end

  test 'admins see the overview and accuracy pages' do
    create_agent_backend!(owner: @alice)
    sign_in_as @admin

    get admin_server_overview_path

    assert_response :success
    get admin_server_accuracy_path

    assert_response :success
  end

  test 'admins can review and fix a workflow model list' do
    workflow = workflows(:sd_image)
    Agent::Requirements.extract!(workflow)
    model = workflow.workflow_models.first
    sign_in_as @admin

    get requirements_admin_workflow_path(workflow)

    assert_response :success
    patch requirements_admin_workflow_path(workflow), params: {
      models: { '0' => { id: model.id, folder: model.folder, filename: model.filename,
                         url: 'https://huggingface.co/x/sd15.safetensors' } }
    }

    assert_equal 'admin', model.reload.source
    assert_equal 'https://huggingface.co/x/sd15.safetensors', model.url
  end

  test 'the studio estimate answers for a workflow' do
    backend = create_agent_backend!(owner: @alice)
    bring_online_for!(backend, workflows(:sd_image))
    sign_in_as @alice

    get estimate_path(generation: { workflow_id: workflows(:sd_image).id }, format: :json)

    assert_response :success
    assert response.parsed_body.key?('summary')
  end

  test 'owners turn a style off from the server page' do
    backend = create_agent_backend!(owner: @alice)
    workflow = workflows(:sd_image)
    row = "##{ActionView::RecordIdentifier.dom_id(workflow, :server_style)}"
    sign_in_as @alice

    get server_path(backend)

    assert_select "#{row} button", text: 'Turn off'

    patch server_styles_path(backend), params: { workflow_id: workflow.id, enabled: '0' }

    assert_response :success
    assert_select "turbo-frame#server_styles_#{backend.id} #{row}" do
      assert_select '.badge', text: 'Off'
      assert_select 'button', text: 'Turn on'
    end
    assert_not backend.reload.allows_workflow?(workflow)
    assert_equal "Turned off #{workflow.name} on #{backend.name}",
                 ActivityLog.where(kind: 'server_updated', subject: backend).last.message
  end

  test 'owners turn a style back on' do
    backend = create_agent_backend!(owner: @alice)
    workflow = workflows(:sd_image)
    backend.set_workflow_enabled!(workflow, false)
    sign_in_as @alice

    patch server_styles_path(backend), params: { workflow_id: workflow.id, enabled: '1' }

    assert_response :success
    assert backend.reload.allows_workflow?(workflow)
  end

  test 'people a server is shared with see a turned-off style but cannot change it' do
    backend = create_agent_backend!(owner: @alice, visibility: 'shared')
    backend.backend_shares.create!(user: @bob)
    workflow = workflows(:sd_image)
    backend.set_workflow_enabled!(workflow, false)
    sign_in_as @bob

    get server_path(backend)

    assert_select "##{ActionView::RecordIdentifier.dom_id(workflow, :server_style)} .badge", text: 'Off'
    assert_select 'button', text: 'Turn on', count: 0

    patch server_styles_path(backend), params: { workflow_id: workflow.id, enabled: '1' }

    assert_response :not_found
    assert_not backend.reload.allows_workflow?(workflow)
  end

  test 'the server list counts only styles that are turned on' do
    backend = create_agent_backend!(owner: @alice)
    backend.set_workflow_enabled!(workflows(:sd_image), false)
    Agent::Availability.recompute_for_backend!(backend)
    sign_in_as @alice

    get servers_path

    assert_response :success
    assert_match "of #{Workflow.enabled.count - 1}", response.body
  end
end

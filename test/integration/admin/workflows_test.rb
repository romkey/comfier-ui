require 'test_helper'

module Admin
  class WorkflowsTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    GRAPH = {
      '1' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'text' => '{{prompt}}' } },
      '2' => { 'class_type' => 'SaveAudio', 'inputs' => { 'seconds' => '{{duration}}' } }
    }.freeze

    setup do
      sign_in_as users(:admin)
    end

    test 'non-admins cannot manage workflows' do
      sign_in_as users(:alice)

      get admin_workflows_path

      assert_response :not_found
    end

    test 'lists workflows by kind and calls out empty kinds' do
      get admin_workflows_path

      assert_response :success
      assert_select 'td a', text: 'SD 1.5'
      assert_select 'td', text: 'height, negative_prompt, prompt, seed, width'
      assert_select 'div', text: /No audio workflows/
    end

    test 'new workflow form preselects the requested kind' do
      get new_admin_workflow_path(kind: 'audio')

      assert_select 'select[name="workflow[kind]"] option[selected][value=audio]'
    end

    test 'the workflow form accepts file uploads' do
      get new_admin_workflow_path

      assert_select 'form[enctype=?]', 'multipart/form-data'
      assert_select '.h-section-label', text: 'ComfyUI exports'
      assert_select 'input[type=file][name="workflow[graph_file]"]'
      assert_select 'input[type=file][name="workflow[models_file]"]'
      assert_select 'button[disabled]', text: 'Suggest placeholders'
    end

    test 'adding a workflow from pasted JSON' do
      post admin_workflows_path,
           params: { workflow: { name: 'Stable Audio', kind: 'audio', graph_json: GRAPH.to_json } }

      workflow = Workflow.find_by!(name: 'Stable Audio')

      assert_redirected_to edit_admin_workflow_path(workflow)
      assert_equal GRAPH, workflow.graph
      assert workflow.uses?(:duration)
    end

    test 'adding a workflow from an uploaded file' do
      file = Rack::Test::UploadedFile.new(StringIO.new(GRAPH.to_json), 'application/json', original_filename: 'wf.json')

      post admin_workflows_path,
           params: { workflow: { name: 'Uploaded', kind: 'audio', graph_json: '', graph_file: file } }

      workflow = Workflow.find_by!(name: 'Uploaded')

      assert_redirected_to edit_admin_workflow_path(workflow)
      assert_equal GRAPH, workflow.graph
    end

    test 'invalid JSON re-renders with the text kept' do
      post admin_workflows_path, params: { workflow: { name: 'Broken', kind: 'audio', graph_json: '{ oops' } }

      assert_response :unprocessable_content
      assert_select '.alert-danger', text: /isn't valid JSON/
      assert_select 'textarea[name="workflow[graph_json]"]', text: '{ oops'
    end

    test 'editing a workflow' do
      workflow = workflows(:sd_image)

      patch admin_workflow_path(workflow), params: { workflow: { enabled: '0', graph_json: workflow.graph_json } }

      assert_redirected_to edit_admin_workflow_path(workflow)
      assert_not workflow.reload.enabled?
    end

    test 'the models list takes download links and drops lines the graph already covers' do
      workflow = workflows(:sd_image)
      text = "# comments are ignored\ncheckpoints/v1-5-pruned-emaonly-fp16.safetensors\n\n" \
             'vae/ae.safetensors https://example.com/ae.safetensors'

      patch admin_workflow_path(workflow), params: { workflow: { required_models_text: text } }

      lines = workflow.reload.extra_models.map { ModelRequirement.from_h(it).to_line }

      assert_equal ['vae/ae.safetensors https://example.com/ae.safetensors'], lines
      assert_equal %w[vae/ae.safetensors checkpoints/v1-5-pruned-emaonly-fp16.safetensors],
                   workflow.required_models.map(&:path)
    end

    test 'a bad models list re-renders with the problem' do
      patch admin_workflow_path(workflows(:sd_image)),
            params: { workflow: { required_models_text: '../evil.safetensors ftp://x' } }

      assert_response :unprocessable_content
      assert_select '.alert-danger', text: /models folder/
      assert_select 'textarea[name="workflow[required_models_text]"]', text: '../evil.safetensors ftp://x'
    end

    test 'both export files can be uploaded together' do
      workflow = workflows(:sd_image)
      api = Rack::Test::UploadedFile.new(StringIO.new(workflow.graph.to_json), 'application/json',
                                         original_filename: 'api.json')
      ui = Rack::Test::UploadedFile.new(StringIO.new(ui_export.to_json), 'application/json',
                                        original_filename: 'ui.json')

      patch admin_workflow_path(workflow), params: { workflow: { graph_file: api, models_file: ui } }

      assert_redirected_to edit_admin_workflow_path(workflow)
      assert_equal 'https://hf.test/sd15.safetensors', workflow.reload.required_models.first.url
    end

    test 'swapped export files are routed correctly with a notice' do
      workflow = workflows(:sd_image)
      api = Rack::Test::UploadedFile.new(StringIO.new(workflow.graph.to_json), 'application/json',
                                         original_filename: 'api.json')
      ui = Rack::Test::UploadedFile.new(StringIO.new(ui_export.to_json), 'application/json',
                                        original_filename: 'ui.json')

      patch admin_workflow_path(workflow), params: { workflow: { graph_file: ui, models_file: api } }

      assert_redirected_to edit_admin_workflow_path(workflow)
      assert_match(/looked swapped/, flash[:notice])
      assert_equal 'https://hf.test/sd15.safetensors', workflow.reload.required_models.first.url
    end

    test 'suggest placeholders rewrites the JSON without saving' do
      workflow = workflows(:sd_image)
      literal_graph = workflow.graph.deep_dup
      literal_graph['6']['inputs']['text'] = 'a cat on a mat'
      workflow.update!(graph: literal_graph)
      suggested = literal_graph.deep_dup
      suggested['6']['inputs']['text'] = '{{prompt}}'
      with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => 'gpt-test') do
        stub_request(:post, 'http://litellm.test/v1/chat/completions')
          .to_return(body: {
            choices: [{ message: { content: { workflow: suggested, notes: 'Prompt only.' }.to_json } }]
          }.to_json)

        patch admin_workflow_path(workflow),
              params: { suggest_placeholders: '1', workflow: { name: workflow.name, kind: workflow.kind,
                                                               graph_json: JSON.pretty_generate(literal_graph) } },
              as: :turbo_stream
      end

      assert_response :success
      assert_select 'turbo-stream[action=replace][target=workflow_placeholder_panel]'
      assert_select 'turbo-stream[action=replace][target=workflow_graph_json_section]'
      assert_select '.h-section-label', text: 'LiteLLM request'
      assert_select 'summary', text: 'Raw reply'
      assert_select 'textarea#workflow_graph_json', text: /"text": "{{prompt}}"/m
      assert_equal 'a cat on a mat', workflow.reload.graph.dig('6', 'inputs', 'text')
    end

    test 'download links can be imported from a UI-format export' do
      workflow = workflows(:sd_image)
      export = { nodes: [{ id: 4, type: 'CheckpointLoaderSimple', properties: { models: [
        { name: 'v1-5-pruned-emaonly-fp16.safetensors', directory: 'checkpoints', url: 'https://hf.test/sd15.safetensors' }
      ] } }], links: [] }
      file = Rack::Test::UploadedFile.new(StringIO.new(export.to_json), 'application/json',
                                          original_filename: 'ui.json')

      patch admin_workflow_path(workflow), params: { workflow: { models_file: file } }

      assert_redirected_to edit_admin_workflow_path(workflow)
      assert_equal 'https://hf.test/sd15.safetensors', workflow.reload.required_models.first.url
    end

    test 'an API-format models file is refused with a hint' do
      file = Rack::Test::UploadedFile.new(StringIO.new(GRAPH.to_json), 'application/json',
                                          original_filename: 'api.json')

      patch admin_workflow_path(workflows(:sd_image)), params: { workflow: { models_file: file } }

      assert_response :unprocessable_content
      assert_select '.alert-danger', text: /not Export \(API\)/
    end

    test 'the edit page loads the models table into a frame' do
      get edit_admin_workflow_path(workflows(:sd_image))

      assert_select 'turbo-frame#workflow_models[src=?]', models_admin_workflow_path(workflows(:sd_image))
    end

    test 'the models table shows each backend’s status and offers installs where possible' do
      backends(:gpu).update!(model_inventory: { 'checkpoints' => [] }, downloader_available: true)
      workflows(:sd_image).update!(required_models_text: 'checkpoints/v1-5-pruned-emaonly-fp16.safetensors https://hf.test/sd15')

      get models_admin_workflow_path(workflows(:sd_image))

      assert_select 'turbo-frame#workflow_models' do
        assert_select 'td', text: /v1-5-pruned-emaonly-fp16.safetensors/
        assert_select '.badge', text: 'Missing'
        assert_select 'form[data-turbo-frame=_top] button', text: 'Install 1 missing'
      end
    end

    test 'the models table explains when a backend has no way to download' do
      backends(:gpu).update!(model_inventory: { 'checkpoints' => [] })

      get models_admin_workflow_path(workflows(:sd_image))

      assert_select 'span', text: /Can't download here/
      assert_select 'button', text: /Install/, count: 0
    end

    test 'installed models are a quiet dot and running downloads say so' do
      backend = backends(:gpu)
      backend.update!(model_inventory: { 'checkpoints' => [], 'vae' => ['ae.safetensors'] }, downloader_available: true)
      workflow = workflows(:sd_image)
      workflow.update!(required_models_text: 'vae/ae.safetensors')
      backend.model_downloads.create!(directory: 'checkpoints', name: 'v1-5-pruned-emaonly-fp16.safetensors',
                                      url: 'https://hf.test/sd15.safetensors', status: :running)

      get models_admin_workflow_path(workflow)

      assert_select '.status-dot.status-success'
      assert_select 'span', text: /Downloading/
    end

    test 're-checking refreshes every enabled backend for the workflow’s folders' do
      backend = backends(:gpu)
      stub_inventory(backend, { checkpoints: ['v1-5-pruned-emaonly-fp16.safetensors'] })

      post check_models_admin_workflow_path(workflows(:sd_image))

      assert_redirected_to edit_admin_workflow_path(workflows(:sd_image), anchor: 'models')
      assert_equal 'Checked every backend.', flash[:notice]
      assert_equal ['v1-5-pruned-emaonly-fp16.safetensors'], backend.reload.model_inventory['checkpoints']
    end

    test 're-checking names the backends it could not reach' do
      stub_request(:get, %r{comfy.test:8188/models/}).to_raise(Errno::ECONNREFUSED)

      post check_models_admin_workflow_path(workflows(:sd_image))

      assert_equal "Couldn't reach GPU box.", flash[:notice]
    end

    test 'installing queues downloads for the missing models that have links' do
      backend = backends(:gpu)
      backend.update!(model_inventory: { 'checkpoints' => [] }, downloader_available: true)
      workflow = workflows(:sd_image)
      workflow.update!(required_models_text: 'checkpoints/v1-5-pruned-emaonly-fp16.safetensors https://hf.test/sd15.safetensors')

      assert_enqueued_with(job: StartModelDownloadJob) do
        post install_models_admin_workflow_path(workflow), params: { backend_id: backend.id }
      end

      assert_redirected_to edit_admin_workflow_path(workflow, anchor: 'models')
      assert_equal '1 download started on GPU box. Progress and any problems show under Models.', flash[:notice]
      assert_equal 'https://hf.test/sd15.safetensors', backend.model_downloads.sole.url
    end

    test 'installing explains models that have no download link' do
      backend = backends(:gpu)
      backend.update!(model_inventory: { 'checkpoints' => [] }, downloader_available: true)

      assert_no_enqueued_jobs do
        post install_models_admin_workflow_path(workflows(:sd_image)), params: { backend_id: backend.id }
      end

      assert_match(/1 file can't be downloaded there/, flash[:notice])
    end

    test 'the models table spells out failed downloads and files that cannot be fetched' do
      backend = backends(:gpu)
      backend.update!(model_inventory: { 'checkpoints' => [], 'vae' => [] }, downloader_available: true)
      workflow = workflows(:sd_image)
      workflow.update!(required_models_text: "vae/ae.safetensors https://hf.test/ae\n" \
                                             'checkpoints/v1-5-pruned-emaonly-fp16.safetensors')
      backend.model_downloads.create!(directory: 'vae', name: 'ae.safetensors', url: 'https://hf.test/ae',
                                      status: :failed, error_message: 'https://hf.test/ae returned HTTP 401.')

      get models_admin_workflow_path(workflow)

      assert_select '.status-panel.status-attention' do
        assert_select 'div', text: '2 files need attention'
        assert_select 'li', text: %r{Download failed.*vae/ae.safetensors.*HTTP 401\. Fix that, then choose Install}m
        assert_select 'li', text: %r{Can't download.*checkpoints/v1-5-pruned-emaonly-fp16\.safetensors.*No download}m
      end
      assert_select 'button', text: 'Install 1 missing'
    end

    test 'a Manager-only backend offers Install only for files in its catalog' do
      backends(:gpu).update!(model_inventory: { 'checkpoints' => [] }, manager_version: '4.2.2', manager_catalog: {})

      get models_admin_workflow_path(workflows(:sd_image))

      assert_select 'button', text: /Install/, count: 0
      assert_select '.status-panel li', text: /Not in ComfyUI-Manager's catalog.*downloader node on GPU box/m

      catalog = { 'checkpoints/v1-5-pruned-emaonly-fp16.safetensors' => 'https://hf.test/sd15' }
      backends(:gpu).update!(manager_catalog: catalog)
      get models_admin_workflow_path(workflows(:sd_image))

      assert_select 'button', text: 'Install 1 missing'
      assert_select '.status-panel', count: 0
    end

    test 'installing on a disabled backend is not found' do
      post install_models_admin_workflow_path(workflows(:sd_image)), params: { backend_id: backends(:offline).id }

      assert_response :not_found
    end

    test 'the list and settings nav call out workflows missing models' do
      backends(:gpu).update!(model_inventory: { 'checkpoints' => [] })

      get admin_workflows_path

      assert_select 'td span.text-warning', text: /Missing on GPU box/
      assert_select '.settings-nav-item.attention', text: /Missing models\s*1/
    end

    test 'the index and edit pages offer delete' do
      get admin_workflows_path

      assert_select 'button', text: 'Delete'

      get edit_admin_workflow_path(workflows(:sdxl_image))

      assert_select 'form[action=?]', admin_workflow_path(workflows(:sdxl_image)) do
        assert_select 'input[name=_method][value=delete]'
        assert_select 'button', text: 'Delete'
      end
    end

    test 'removing a workflow keeps past generations' do
      assert_difference('Workflow.count', -1) { delete admin_workflow_path(workflows(:sd_image)) }
      assert_nil generations(:alice_done).reload.workflow
    end

    private

    def ui_export
      { nodes: [{ id: 4, type: 'CheckpointLoaderSimple', properties: { models: [
        { name: 'v1-5-pruned-emaonly-fp16.safetensors', directory: 'checkpoints',
          url: 'https://hf.test/sd15.safetensors' }
      ] } }], links: [] }
    end
  end
end

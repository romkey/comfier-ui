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
      assert_select 'button[name=suggest_placeholders]:not([disabled])', text: /Suggest placeholders/
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

    test 'suggest placeholders proposes a review table without changing the JSON or saving' do
      workflow = workflows(:sd_image)
      literal = literal_graph(workflow)
      workflow.update!(graph: literal)

      patch admin_workflow_path(workflow),
            params: { suggest_placeholders: '1', workflow: { name: workflow.name, kind: workflow.kind,
                                                             graph_json: JSON.pretty_generate(literal) } },
            as: :turbo_stream

      assert_response :success
      assert_select 'turbo-stream[action=replace][target=workflow_placeholder_panel]' do
        assert_select 'tbody tr', 4
        assert_select 'input[type=checkbox][name="placeholder_substitutions[0][apply]"][checked]'
        assert_select 'td code', text: '{{prompt}}'
        assert_select 'td', text: '"a cat on a mat"'
      end
      assert_select 'textarea#workflow_graph_json', text: /"text": "a cat on a mat"/m
      assert_equal 'a cat on a mat', workflow.reload.graph.dig('6', 'inputs', 'text')
    end

    test 'the placeholder review offers the remaining literal inputs and the details' do
      workflow = workflows(:sd_image)

      patch admin_workflow_path(workflow),
            params: { suggest_placeholders: '1',
                      workflow: { graph_json: JSON.pretty_generate(literal_graph(workflow)) } },
            as: :turbo_stream

      assert_select 'select[data-placeholder-review-target=target] option', text: /filename_prefix/
      assert_select 'select[data-placeholder-review-target=target] option', text: /seed/, count: 0
      assert_select 'template[data-placeholder-review-target=template] ' \
                    'input[name="placeholder_substitutions[__INDEX__][source]"][value=manual]'
      assert_select 'summary', text: 'Details'
      assert_select 'p', text: /The rules classified every input/
    end

    test 'suggest placeholders explains a UI-format upload' do
      patch admin_workflow_path(workflows(:sd_image)),
            params: { suggest_placeholders: '1', workflow: { graph_json: ui_export.to_json } }, as: :turbo_stream

      assert_response :unprocessable_content
      assert_select '.alert-danger', text: /UI-format workflow. In ComfyUI, use Export \(API\)/
    end

    test 'saving applies only the ticked placeholder rows' do
      workflow = workflows(:sd_image)
      literal = literal_graph(workflow)
      rows = {
        '0' => { node: '6', input: 'text', placeholder: 'prompt', source: 'rule', apply: '1' },
        '1' => { node: '3', input: 'steps', placeholder: 'steps', source: 'rule' },
        '2' => { node: '3', input: 'model', placeholder: 'image', source: 'manual', apply: '1' }
      }

      patch admin_workflow_path(workflow),
            params: { workflow: { graph_json: JSON.pretty_generate(literal) }, placeholder_substitutions: rows }

      assert_redirected_to edit_admin_workflow_path(workflow)
      assert_match(/Applied 1 placeholder. Skipped 1: node 3 input "model" is wired/, flash[:notice])
      graph = workflow.reload.graph

      assert_equal '{{prompt}}', graph.dig('6', 'inputs', 'text')
      assert_equal 20, graph.dig('3', 'inputs', 'steps')
      assert_equal ['4', 0], graph.dig('3', 'inputs', 'model')
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
      assert_select '.status-panel li', text: /Not in ComfyUI-Manager's catalog.*Switch GPU box to the Comfier Agent/m

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

    test 'removing a workflow that has timing data keeps the data for its structure' do
      workflow = workflows(:sd_image)
      backend = backends(:gpu)
      sample = PerfSample.create!(backend:, workflow:, structure_hash: 'abc', completed_at: Time.current)
      stat = PerfStat.create!(backend:, workflow:, structure_hash: 'abc')

      assert_difference('Workflow.count', -1) { delete admin_workflow_path(workflow) }
      assert_redirected_to admin_workflows_path
      assert_nil sample.reload.workflow_id
      assert_equal 'abc', stat.reload.structure_hash
      assert_nil stat.workflow_id
    end

    test 'the form offers engines and their presets' do
      get new_admin_workflow_path(engine: 'mflux')

      assert_response :success
      assert_select 'select[name="workflow[engine]"] option[selected][value="mflux"]'
      assert_select '#engine_preset option[data-engine="mflux"][value="z-image-turbo"]'
      assert_select '#engine_preset option[data-engine="mlx_video"]'
      assert_select 'label[for="workflow_graph_json"]', 'Recipe (JSON)'
    end

    test 'adding an mflux workflow from a recipe' do
      recipe = EnginePreset::ALL.find { it.key == 'z-image-turbo' }

      post admin_workflows_path, params: { workflow: { name: 'Z-Image', kind: 'image', engine: 'mflux',
                                                       graph_json: recipe.to_json_text } }

      workflow = Workflow.find_by!(name: 'Z-Image')

      assert_equal 'mflux', workflow.engine
      assert_equal 'mflux-generate-z-image-turbo', workflow.graph['command']
      get admin_workflows_path

      assert_select 'td', text: /z-image-turbo/
    end

    test 'a bad recipe re-renders with the reason' do
      post admin_workflows_path, params: { workflow: { name: 'Bad', kind: 'image', engine: 'mflux',
                                                       graph_json: '{"model": "dev"}' } }

      assert_response :unprocessable_content
      assert_select '.alert-danger', /Recipe needs "command"/
    end

    private

    # The SD fixture with its prompt, size and seed written out as the literals a fresh export has.
    def literal_graph(workflow)
      workflow.graph.deep_dup.tap do |graph|
        graph['6']['inputs']['text'] = 'a cat on a mat'
        graph['3']['inputs']['seed'] = 42
      end
    end

    def ui_export
      { nodes: [{ id: 4, type: 'CheckpointLoaderSimple', properties: { models: [
        { name: 'v1-5-pruned-emaonly-fp16.safetensors', directory: 'checkpoints',
          url: 'https://hf.test/sd15.safetensors' }
      ] } }], links: [] }
    end
  end
end

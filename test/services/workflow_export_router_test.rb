require 'test_helper'

class WorkflowExportRouterTest < ActiveSupport::TestCase
  UI_EXPORT = {
    nodes: [{ id: 4, type: 'CheckpointLoaderSimple', properties: { models: [
      { name: 'v1-5-pruned-emaonly-fp16.safetensors', directory: 'checkpoints', url: 'https://hf.test/sd15.safetensors' }
    ] } }], links: []
  }.freeze

  test 'routes API and UI exports to graph and model imports' do
    workflow = Workflow.new
    api = upload(api_graph.to_json, 'api.json')
    ui = upload(UI_EXPORT.to_json, 'ui.json')

    result = WorkflowExportRouter.route(workflow, graph_file: api, models_file: ui)

    assert_includes result.graph_content, '"class_type": "CLIPTextEncode"'
    assert_includes result.models_content, 'hf.test/sd15.safetensors'
    assert_nil result.swap_notice
  end

  test 'routes a lone UI export upload to model links' do
    workflow = Workflow.new
    ui = upload(UI_EXPORT.to_json, 'ui.json')

    result = WorkflowExportRouter.route(workflow, graph_file: ui, models_file: nil)

    assert_nil result.graph_content
    assert_includes result.models_content, 'hf.test/sd15.safetensors'
  end

  test 'swaps exports that were uploaded into the wrong slots' do
    workflow = Workflow.new
    api = upload(api_graph.to_json, 'api.json')
    ui = upload(UI_EXPORT.to_json, 'ui.json')

    result = WorkflowExportRouter.route(workflow, graph_file: ui, models_file: api)

    assert_includes result.graph_content, '"class_type": "CLIPTextEncode"'
    assert_match(/looked swapped/, result.swap_notice)
  end

  private

  def api_graph = workflows(:sd_image).graph

  def upload(json, name)
    Rack::Test::UploadedFile.new(StringIO.new(json), 'application/json', original_filename: name)
  end
end

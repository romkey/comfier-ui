require 'test_helper'

class WorkflowTest < ActiveSupport::TestCase
  API_GRAPH = { '1' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'text' => '{{prompt}}' } } }.freeze

  test 'finds every placeholder in the graph' do
    assert_equal %w[height negative_prompt prompt seed width], workflows(:sd_image).placeholders.sort
    assert workflows(:sd_image).uses?(:prompt)
    assert workflows(:sd_image).uses?(:image, :width)
    assert_not workflows(:sd_image).uses?(:image)
  end

  test 'finds placeholders embedded in longer strings' do
    assert workflows(:wan_video).uses?(:prompt)
  end

  test 'accepts API-format JSON through graph_json' do
    workflow = Workflow.new(name: 'New', kind: 'image', graph_json: API_GRAPH.to_json)

    assert_predicate workflow, :valid?
    assert_equal API_GRAPH, workflow.graph
    workflow.save!

    assert_includes Workflow.find(workflow.id).graph_json, '"class_type": "CLIPTextEncode"'
  end

  test 'accepts bare placeholders in numeric slots and keeps the typed text' do
    typed = <<~JSON.strip
      {
        "1": {
          "class_type": "EmptyLatentImage",
          "inputs": {
            "width": {{width}},
            "height": {{height}},
            "batch_size": 1
          }
        }
      }
    JSON
    workflow = Workflow.new(name: 'Bare placeholders', kind: 'image', graph_json: typed)

    assert_predicate workflow, :valid?
    assert_equal typed, workflow.graph_json
    assert_equal '{{width}}', workflow.graph.dig('1', 'inputs', 'width')
    assert_equal '{{height}}', workflow.graph.dig('1', 'inputs', 'height')
  end

  test 'normalize_graph_json leaves quoted placeholders and strings alone' do
    json = '{"a": "{{prompt}}", "b": "prefix {{seed}} suffix", "c": {{width}}}'

    assert_equal '{"a": "{{prompt}}", "b": "prefix {{seed}} suffix", "c": "{{width}}"}',
                 WorkflowGraphJson.normalize(json)
  end

  test 'rejects invalid JSON but keeps what the admin typed' do
    workflow = Workflow.new(name: 'New', kind: 'image', graph_json: '{ nope')

    assert_not workflow.valid?
    assert_match(/isn't valid JSON/, workflow.errors[:graph_json].first)
    assert_equal '{ nope', workflow.graph_json
  end

  test 'explains when the UI format was pasted instead of the API format' do
    workflow = Workflow.new(name: 'New', kind: 'image', graph_json: { nodes: [], links: [] }.to_json)

    assert_not workflow.valid?
    assert_match(/Export \(API\)/, workflow.errors[:graph_json].first)
  end

  test 'rejects graphs whose nodes are not ComfyUI nodes' do
    assert_not Workflow.new(name: 'A', kind: 'image', graph: {}).valid?
    assert_not Workflow.new(name: 'B', kind: 'image', graph: { '1' => { 'inputs' => {} } }).valid?
    assert_not Workflow.new(name: 'C', kind: 'image', graph_json: '[1, 2]').valid?
  end

  test 'rejects unknown placeholders' do
    graph = { '1' => { 'class_type' => 'X', 'inputs' => { 'a' => '{{prompt}}', 'b' => '{{mystery}}' } } }
    workflow = Workflow.new(name: 'New', kind: 'image', graph:)

    assert_not workflow.valid?
    assert_match(/unknown placeholders: mystery/, workflow.errors[:graph_json].first)
  end

  test 'placeholders are recomputed when the graph changes' do
    workflow = workflows(:sd_image)

    assert workflow.uses?(:seed)
    workflow.graph = API_GRAPH

    assert_not workflow.uses?(:seed)
  end

  test 'kind must be a known generation kind' do
    assert_not Workflow.new(name: 'New', kind: 'hologram', graph: API_GRAPH).valid?
  end

  test 'names are unique within a kind' do
    assert_not Workflow.new(name: 'sd 1.5', kind: 'image', graph: API_GRAPH).valid?
    assert_predicate Workflow.new(name: 'SD 1.5', kind: 'video', graph: API_GRAPH), :valid?
  end

  test 'required models combine the admin list with what the graph loads' do
    workflow = workflows(:sd_image)
    workflow.required_models_text = "checkpoints/v1-5-pruned-emaonly-fp16.safetensors https://hf.test/sd15\n" \
                                    'loras/extra.safetensors'

    assert_equal ['checkpoints/v1-5-pruned-emaonly-fp16.safetensors https://hf.test/sd15', 'loras/extra.safetensors'],
                 workflow.required_models.map(&:to_line)
  end

  test 'required models follow graph changes' do
    workflow = workflows(:sd_image)

    assert_equal 1, workflow.required_models.size
    workflow.graph = API_GRAPH

    assert_empty workflow.required_models
  end

  test 'saving drops link-less lines the graph already provides' do
    workflow = workflows(:sd_image)
    workflow.update!(required_models_text: workflow.required_models_text)

    assert_empty workflow.reload.extra_models
  end

  test 'model_directories covers every workflow' do
    workflows(:wan_video).update!(required_models_text: 'vae/wan.safetensors https://hf.test/wan')

    assert_equal %w[checkpoints vae], Workflow.model_directories.sort
  end

  test 'import_models keeps typed links and fills in the rest' do
    workflow = workflows(:sd_image)
    workflow.required_models_text = 'vae/ae.safetensors https://mine.test/ae'
    export = { 'nodes' => [{ 'properties' => { 'models' => [
      { 'name' => 'ae.safetensors', 'directory' => 'vae', 'url' => 'https://theirs.test/ae' },
      { 'name' => 'v1-5-pruned-emaonly-fp16.safetensors', 'directory' => 'checkpoints', 'url' => 'https://hf.test/sd15' }
    ] } }], 'links' => [] }

    assert_equal 2, workflow.import_models(export.to_json)
    assert_equal ['vae/ae.safetensors https://mine.test/ae', 'checkpoints/v1-5-pruned-emaonly-fp16.safetensors https://hf.test/sd15'],
                 workflow.required_models.map(&:to_line)
    assert_predicate workflow, :valid?
  end

  test 'import_models refuses API-format and broken files' do
    workflow = workflows(:sd_image)
    workflow.import_models(API_GRAPH.to_json)

    assert_not workflow.valid?
    assert_match(/not Export \(API\)/, workflow.errors[:models_file].join)

    workflow = workflows(:sd_image)
    workflow.import_models('{ nope')

    assert_not workflow.valid?
    assert_match(/isn't valid JSON/, workflow.errors[:models_file].join)
  end
end

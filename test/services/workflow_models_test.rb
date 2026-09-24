require 'test_helper'

class WorkflowModelsTest < ActiveSupport::TestCase
  def node(class_type, inputs) = { 'class_type' => class_type, 'inputs' => inputs }

  test 'infers files from well-known loader inputs' do
    graph = {
      '1' => node('UNETLoader', 'unet_name' => 'wan\\t2v.safetensors', 'weight_dtype' => 'default'),
      '2' => node('DualCLIPLoader', 'clip_name1' => 'clip_l.safetensors', 'clip_name2' => 't5.safetensors'),
      '3' => node('CLIPVisionLoader', 'clip_name' => 'vision.safetensors'),
      '4' => node('UpscaleModelLoader', 'model_name' => '4x.pth'),
      '5' => node('VAELoader', 'vae_name' => 'ae.safetensors')
    }

    assert_equal %w[diffusion_models/wan/t2v.safetensors text_encoders/clip_l.safetensors text_encoders/t5.safetensors
                    clip_vision/vision.safetensors upscale_models/4x.pth vae/ae.safetensors],
                 WorkflowModels.infer(graph).map(&:path)
  end

  test 'ignores placeholders, non-model values and unknown inputs' do
    graph = {
      '1' => node('LoadImage', 'image' => '{{image}}'),
      '2' => node('CheckpointLoaderSimple', 'ckpt_name' => '{{model}}.safetensors'),
      '3' => node('SomethingCustom', 'model_name' => 'mystery.safetensors'),
      '4' => node('SaveImage', 'filename_prefix' => 'out.safetensors', 'images' => ['1', 0])
    }

    assert_empty WorkflowModels.infer(graph)
    assert_empty WorkflowModels.infer('not a graph')
  end

  test 'lists each file once' do
    graph = { '1' => node('LoraLoader', 'lora_name' => 'a.safetensors'),
              '2' => node('LoraLoader', 'lora_name' => 'a.safetensors') }

    assert_equal ['loras/a.safetensors'], WorkflowModels.infer(graph).map(&:path)
  end

  test 'reads download links from UI-format nodes and subgraphs' do
    data = {
      'nodes' => [
        { 'type' => 'VAELoader', 'properties' => { 'models' => [
          { 'name' => 'ae.safetensors', 'directory' => 'vae', 'url' => 'https://hf.test/ae.safetensors' }
        ] } },
        { 'type' => 'Note', 'properties' => {} }
      ],
      'links' => [],
      'definitions' => { 'subgraphs' => [{ 'nodes' => [
        { 'properties' => { 'models' => [{ 'name' => 'unet.safetensors', 'directory' => 'diffusion_models' },
                                         { 'name' => '', 'directory' => 'vae' }] } }
      ] }] }
    }

    assert_equal ['vae/ae.safetensors https://hf.test/ae.safetensors', 'diffusion_models/unet.safetensors'],
                 WorkflowModels.from_ui_workflow(data).map(&:to_line)
    assert_empty WorkflowModels.from_ui_workflow({ '1' => node('VAELoader', {}) })
  end

  test 'merging keeps the first entry and fills in a missing link' do
    bare = ModelRequirement.parse_line('vae/ae.safetensors')
    linked = ModelRequirement.parse_line('vae/ae.safetensors https://hf.test/ae')
    other = ModelRequirement.parse_line('vae/ae.safetensors https://elsewhere.test/ae')

    assert_equal [linked], WorkflowModels.merge([bare], [linked])
    assert_equal [linked], WorkflowModels.merge([linked], [other])
  end
end

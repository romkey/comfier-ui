# frozen_string_literal: true

require 'test_helper'

module Agent
  class RequirementsTest < ActiveSupport::TestCase
    API = {
      '1' => { 'class_type' => 'CheckpointLoaderSimple', 'inputs' => { 'ckpt_name' => 'sd15/model.safetensors' } },
      '2' => { 'class_type' => 'MysteryLoader', 'inputs' => { 'weights' => 'mystery.safetensors' } },
      '3' => { 'class_type' => 'LoraLoader', 'inputs' => { 'lora_name' => '{{seed}}' } }
    }.freeze
    UI = {
      'nodes' => [
        { 'id' => 1, 'type' => 'CheckpointLoaderSimple',
          'properties' => { 'models' => [{ 'name' => 'model.safetensors', 'directory' => 'checkpoints',
                                           'url' => 'https://huggingface.co/x/model.safetensors',
                                           'hash' => 'a' * 64, 'hash_type' => 'SHA256' }] } },
        { 'id' => 2, 'type' => 'MysteryLoader',
          'properties' => { 'models' => [{ 'name' => 'mystery.safetensors', 'directory' => 'upscale_models',
                                           'url' => 'https://huggingface.co/x/mystery.safetensors' }] } }
      ],
      'links' => [],
      'models' => [{ 'name' => 'extra_vae.safetensors', 'directory' => 'vae', 'url' => 'https://huggingface.co/x/vae' }]
    }.freeze

    def workflow_with(graph: API, ui: UI)
      Workflow.create!(name: "Req #{SecureRandom.hex(3)}", kind: 'image', graph:, ui_graph: ui, enabled: true)
    end

    def row(workflow, filename) = workflow.workflow_models.find_by(filename:)

    test 'API models join UI metadata by exact name or basename' do
      workflow = workflow_with
      model = row(workflow, 'sd15/model.safetensors')

      assert_equal 'checkpoints', model.folder
      assert_equal 'https://huggingface.co/x/model.safetensors', model.url
      assert_equal 'a' * 64, model.sha256
    end

    test 'an unknown folder takes the directory from the UI export' do
      assert_equal 'upscale_models', row(workflow_with, 'mystery.safetensors').folder
    end

    test 'top-level UI models are included and placeholders are not' do
      workflow = workflow_with

      assert_equal 'vae', row(workflow, 'extra_vae.safetensors').folder
      assert_not workflow.workflow_models.exists?(filename: '{{seed}}')
    end

    test 'node types come from the API graph' do
      assert_equal %w[CheckpointLoaderSimple LoraLoader MysteryLoader], Requirements.for(workflow_with).node_types
    end

    test 'the structure hash ignores key order' do
      reordered = API.to_a.reverse.to_h.transform_values { it.to_a.reverse.to_h }

      assert_equal Requirements.structure_hash(API), Requirements.structure_hash(reordered)
      assert_not_equal Requirements.structure_hash(API), Requirements.structure_hash(API.merge('4' => {}))
    end

    test 'unknown folders without UI metadata need review' do
      workflow = workflow_with(ui: nil)

      assert_equal 'unknown', row(workflow, 'mystery.safetensors').folder
      assert_predicate workflow.reload, :requirements_need_review?
    end

    test 'admin edits survive re-extraction' do
      workflow = workflow_with(ui: nil)
      WorkflowRequirementsEditor.new(workflow).apply!(
        [{ 'id' => row(workflow, 'mystery.safetensors').id, 'folder' => 'upscale_models',
           'filename' => 'mystery.safetensors', 'url' => 'https://huggingface.co/x/fixed.safetensors' }]
      )
      Requirements.extract!(workflow)

      rows = workflow.workflow_models.where(filename: 'mystery.safetensors')

      assert_equal [%w[upscale_models admin]], rows.pluck(:folder, :source)
      assert_equal 'https://huggingface.co/x/fixed.safetensors', rows.first.url
      assert_not workflow.workflow_models.exists?(folder: 'unknown')
    end

    test 'the model set hash names folder and file, in any order' do
      a = [{ 'folder' => 'vae', 'filename' => 'a' }, { 'folder' => 'loras', 'filename' => 'b' }]

      assert_equal Requirements.model_set_hash(a), Requirements.model_set_hash(a.reverse)
    end

    test 'enrichment fills size and hash from Hugging Face headers' do
      node = UI['nodes'].first.deep_dup
      node['properties']['models'][0].delete('hash')
      workflow = workflow_with(graph: API.slice('1'), ui: { 'nodes' => [node], 'links' => [] })
      stub_request(:head, 'https://huggingface.co/x/model.safetensors')
        .to_return(status: 302, headers: { 'X-Linked-Size' => '2132625894', 'X-Linked-Etag' => "\"#{'b' * 64}\"" })

      EnrichWorkflowModelsJob.perform_now(workflow)
      model = row(workflow, 'sd15/model.safetensors')

      assert_equal 2_132_625_894, model.bytes
      assert_equal 'b' * 64, model.sha256
      assert_equal 'enriched', model.source
    end

    test 'enrichment finds the official fp16 version of an fp8 file' do
      workflow = workflow_with
      fp8 = row(workflow, 'mystery.safetensors')
      fp8.update!(filename: 'wan_fp8_scaled.safetensors', url: 'https://huggingface.co/x/wan_fp8_scaled.safetensors',
                  bytes: 1)
      stub_request(:head, /huggingface/).to_return(status: 404)
      stub_request(:head, 'https://huggingface.co/x/wan_fp16.safetensors')
        .to_return(status: 302, headers: { 'X-Linked-Size' => '28', 'X-Linked-Etag' => "\"#{'c' * 64}\"" })

      EnrichWorkflowModelsJob.perform_now(workflow)
      fp8.reload

      assert_equal ['https://huggingface.co/x/wan_fp16.safetensors', 28, 'c' * 64],
                   [fp8.fp16_url, fp8.fp16_bytes, fp8.fp16_sha256]
      assert_equal 'https://huggingface.co/x/wan_fp16.safetensors', fp8.to_requirement_h['fp16_url']
    end

    test 'enriched values survive re-extraction when the link is unchanged' do
      workflow = workflow_with
      row(workflow, 'mystery.safetensors').update!(bytes: 123, source: 'enriched')
      Requirements.extract!(workflow)

      assert_equal 123, row(workflow, 'mystery.safetensors').bytes
    end
  end
end

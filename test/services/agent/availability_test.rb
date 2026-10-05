# frozen_string_literal: true

require 'test_helper'

module Agent
  class AvailabilityTest < ActiveSupport::TestCase
    setup do
      @workflow = workflows(:sd_image)
      @backend = create_agent_backend!(owner: users(:alice))
      @node_types = inventory_for(@workflow)[:node_types]
    end

    def compute = Availability.compute(@workflow, @backend.reload)

    test 'blocked until the server reports its models' do
      assert_predicate compute, :blocked?
    end

    test 'ready when every model and node type is present' do
      bring_online_for!(@backend, @workflow)

      assert_predicate compute, :ready?
    end

    test 'object_info counts as installed even when inventory node_types are stale' do
      bring_online_for!(@backend, @workflow)
      stale = Array(@backend.backend_inventory.node_types_json) - @node_types.first(1)
      @backend.backend_inventory.update!(node_types_json: stale)

      info = @node_types.index_with { { 'input' => { 'required' => {} } } }
      store_object_info(info)

      assert_predicate compute, :ready?
    end

    test 'folder aliases count as the same folder' do
      matcher = ModelMatcher.new([%w[diffusion_models flux.safetensors], %w[text_encoders t5.safetensors]])

      assert matcher.present?('unet', 'flux.safetensors')
      assert matcher.present?('clip', 't5.safetensors')
      assert_not matcher.present?('vae', 'flux.safetensors')
    end

    test 'a file in another subdirectory is a hint, not a match' do
      bring_online!(@backend, models: { 'checkpoints' => ['old/v1-5-pruned-emaonly-fp16.safetensors'] },
                              node_types: @node_types)
      result = compute

      assert_predicate result, :blocked?
      assert_match 'is at checkpoints/old/v1-5-pruned-emaonly-fp16.safetensors', result.hints.first
    end

    test 'a missing model with a link needs downloads' do
      set_model_links(@workflow, url: 'https://hf.test/sd15', bytes: 2.gigabytes)
      bring_online!(@backend, node_types: @node_types)
      result = compute

      assert_predicate result, :needs_downloads?
      assert_equal 2.gigabytes, result.total_bytes
    end

    test 'stored availability records how many models the workflow needs' do
      set_model_links(@workflow, url: 'https://hf.test/sd15')
      bring_online!(@backend, node_types: @node_types)
      Availability.store!(@workflow, @backend)
      record = WorkflowAvailability.find_by!(workflow: @workflow, backend: @backend)

      assert_equal Agent::Requirements.for(@workflow).models.size, record.details['required_model_count']
    end

    test 'missing models are blocked when downloads are off' do
      set_model_links(@workflow, url: 'https://hf.test/sd15')
      bring_online!(@backend, node_types: @node_types)
      @backend.update!(model_downloads_enabled: false)

      assert_match "doesn't allow model downloads", compute.reasons.first
    end

    test 'not enough disk blocks downloads' do
      set_model_links(@workflow, url: 'https://hf.test/sd15', bytes: 8.gigabytes)
      bring_online!(@backend, node_types: @node_types, disk_free: { 'models' => 15.gigabytes })

      assert_match 'Not enough disk space', compute.reasons.first
    end

    test 'with object_info, list inputs must hold an available value' do
      bring_online_for!(@backend, @workflow)
      info = { 'KSampler' => { 'input' => { 'required' => { 'sampler_name' => [%w[euler dpmpp_2m]] } } } }
      store_object_info(info)
      @workflow.update!(graph: @workflow.graph.deep_merge('3' => { 'inputs' => { 'sampler_name' => 'res_multistep' } }))
      result = compute

      assert_predicate result, :blocked?
      assert_match 'sampler_name “res_multistep” isn\'t available', result.reasons.first
    end

    test 'COMBO option specs are understood' do
      info = { 'X' => { 'input' => { 'optional' => { 'mode' => ['COMBO', { 'options' => %w[a b] }] } } } }

      assert_equal %w[a b], ObjectInfoStore.options_for(info, 'X', 'mode')
      assert_nil ObjectInfoStore.options_for(info, 'X', 'other')
    end

    test 'object_info arrives in chunks and is reassembled' do
      bring_online_for!(@backend, @workflow)
      info = { 'KSampler' => { 'input' => { 'required' => {} } } }

      assert store_object_info(info, chunks: 3)
      assert_equal info, @backend.backend_object_infos.first.data
    end

    test 'availability is cached per workflow and server' do
      bring_online_for!(@backend, @workflow)
      Availability.recompute_for_backend!(@backend)

      assert_equal 'ready', WorkflowAvailability.find_by(workflow: @workflow, backend: @backend).status
    end

    def store_object_info(info, chunks: 1)
      encoded = Base64.strict_encode64(ActiveSupport::Gzip.compress(info.to_json))
      size = (encoded.length / chunks.to_f).ceil
      parts = encoded.scan(/.{1,#{size}}/o)
      parts.each_with_index do |data, index|
        agent_message(@backend, { 'type' => 'object_info', 'hash' => 'oi1', 'index' => index, 'count' => parts.size,
                                  'encoding' => 'gzip+base64', 'data' => data })
      end
      @backend.backend_object_infos.reload.first
    end
  end
end

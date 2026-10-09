# frozen_string_literal: true

require 'test_helper'

module Agent
  class MessageHandlerTest < ActiveJob::TestCase
    setup do
      @backend = create_agent_backend!(owner: users(:alice))
      @hash = 'fixed-inventory-hash'
      agent_inventory(@backend, models: { 'checkpoints' => ['a.safetensors'] }, node_types: %w[CLIPLoader], hash: @hash)
    end

    test 'inventory with an unchanged hash still recomputes style availability' do
      models = { 'checkpoints' => ['a.safetensors'] }
      assert_enqueued_with(job: RecomputeAvailabilityJob, args: [{ backend_id: @backend.id }]) do
        agent_inventory(@backend, models:, node_types: %w[CLIPLoader], hash: @hash)
      end
    end

    test 'an inventory without engines means ComfyUI only' do
      assert_equal({ 'comfyui' => {} }, @backend.reload.engines)
      assert @backend.runs_engine?(:comfyui)
      assert_not @backend.runs_engine?(:mflux)
    end

    test 'inventory stores the engines a server reports' do
      engines = { comfyui: {}, mflux: { version: '0.9.0', models: %w[qwen-image] } }
      agent_inventory(@backend, models: { 'checkpoints' => ['a.safetensors'] }, node_types: %w[CLIPLoader], engines:)

      @backend.reload

      assert @backend.runs_engine?('mflux')
      assert_equal %w[qwen-image], @backend.engine_models('mflux')
      assert_equal '0.9.0', @backend.engine_info(:mflux)['version']
    end

    test 'an empty engines map means nothing is available, and waiting jobs go elsewhere' do
      other = create_agent_backend!(owner: users(:alice), name: 'Other box')
      bring_online_for!(other, workflows(:sd_image))
      gen = Generation.create!(user: users(:alice), workflow: workflows(:sd_image), prompt: 'x', kind: :image,
                               status: :queued, backend: @backend, agent_state: 'queued',
                               filled_workflow_json: { '1' => {} }, queued_at: Time.current)

      agent_inventory(@backend, models: { 'checkpoints' => ['a.safetensors'] }, node_types: %w[CLIPLoader],
                                engines: {})

      assert_empty @backend.reload.engines
      assert_not @backend.runs_engine?(:comfyui)
      assert_equal other.id, gen.reload.backend_id
    end
  end
end

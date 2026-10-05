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
  end
end

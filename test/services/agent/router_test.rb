# frozen_string_literal: true

require 'test_helper'

module Agent
  class RouterTest < ActiveSupport::TestCase
    setup do
      @alice = users(:alice)
      @bob = users(:bob)
      @workflow = workflows(:sd_image)
      Backend.legacy.update_all(enabled: false) # rubocop:disable Rails/SkipsModelValidations
    end

    def routing_job(user: @alice, **attrs)
      Generation.create!({ user:, workflow: @workflow, prompt: 'x', kind: :image, status: :queued,
                           agent_state: 'routing', filled_workflow_json: { '1' => {} } }.merge(attrs))
    end

    test 'routes to an online server that has everything' do
      backend = create_agent_backend!(owner: @alice)
      bring_online_for!(backend, @workflow)
      gen = routing_job

      assert_equal backend, Router.route!(gen)
      assert_equal 'queued', gen.reload.agent_state
      assert_equal backend.id, gen.backend_id
      assert_predicate gen.predicted_total_ms, :positive?
    end

    test 'private servers are invisible to other users' do
      backend = create_agent_backend!(owner: @alice)
      bring_online_for!(backend, @workflow)

      error = assert_raises(Router::UnroutableError) { Router.route!(routing_job(user: @bob)) }
      assert_equal Router::NO_SERVERS, error.message
    end

    test 'shared servers are usable by the people they are shared with' do
      backend = create_agent_backend!(owner: @alice, visibility: 'shared')
      backend.backend_shares.create!(user: @bob)
      bring_online_for!(backend, @workflow)

      assert_equal backend, Router.route!(routing_job(user: @bob))
    end

    test 'mine_only waits for the owner server instead of failing' do
      backend = create_agent_backend!(owner: @alice)
      public_box = create_agent_backend!(owner: @bob, name: 'Public box', visibility: 'public')
      bring_online_for!(public_box, @workflow)
      @alice.update!(backend_affinity: 'mine_only')
      gen = routing_job
      connect_agent!(backend)

      assert_nil Router.route!(gen)
      assert_equal 'routing', gen.reload.agent_state
      assert_equal 'waiting_for_server', gen.agent_phase
    end

    test 'prefer_mine uses the own server when it is online' do
      own = create_agent_backend!(owner: @alice)
      other = create_agent_backend!(owner: @bob, name: 'Other', visibility: 'public')
      [own, other].each { bring_online_for!(it, @workflow) }
      set_speed(other, 0.1)

      assert_equal own, Router.route!(routing_job)
    end

    test 'excluded servers are skipped' do
      backend = create_agent_backend!(owner: @alice)
      bring_online_for!(backend, @workflow)
      gen = routing_job(excluded_backend_ids: [backend.id])

      assert_raises(Router::UnroutableError) { Router.route!(gen) }
    end

    test 'the queue limit applies to other users only' do
      backend = create_agent_backend!(owner: @alice, visibility: 'public', max_queued_per_other_user: 1)
      bring_online_for!(backend, @workflow)
      routing_job(user: @bob, backend:, agent_state: 'queued')

      error = assert_raises(Router::UnroutableError) { Router.route!(routing_job(user: @bob)) }
      assert_match 'queue limit', error.message
      assert_equal backend, Router.route!(routing_job)
    end

    test 'servers missing models are not chosen' do
      backend = create_agent_backend!(owner: @alice)
      bring_online!(backend, node_types: inventory_for(@workflow)[:node_types])
      set_model_links(@workflow, url: 'https://hf.test/sd15.safetensors', bytes: 2.gigabytes)

      error = assert_raises(Router::UnroutableError) { Router.route!(routing_job) }
      assert_match 'missing models', error.message
    end

    test 'paused servers are not chosen' do
      paused = create_agent_backend!(owner: @alice, name: 'Paused box', paused: true)
      ready = create_agent_backend!(owner: @bob, name: 'Ready box', visibility: 'public')
      [paused, ready].each { bring_online_for!(it, @workflow) }

      assert_equal ready, Router.route!(routing_job)
    end

    test 'missing node types block with an explanation' do
      backend = create_agent_backend!(owner: @alice)
      inv = inventory_for(@workflow)
      bring_online!(backend, models: inv[:models], node_types: inv[:node_types] - ['CLIPTextEncode'])

      error = assert_raises(Router::UnroutableError) { Router.route!(routing_job) }
      assert_match 'Agent box', error.message
      assert_match 'Node type CLIPTextEncode isn\'t installed', error.message
    end

    test 'min_vram skips smaller cards' do
      backend = create_agent_backend!(owner: @alice)
      bring_online_for!(backend, @workflow)

      assert_raises(Router::UnroutableError) { Router.route!(routing_job, min_vram: 24.gigabytes) }
    end

    test 'the earliest finish wins' do
      slow = create_agent_backend!(owner: @alice, name: 'Slow')
      fast = create_agent_backend!(owner: @alice, name: 'Fast')
      [slow, fast].each { bring_online_for!(it, @workflow) }
      set_speed(slow, 4.0)
      set_speed(fast, 0.25)

      assert_equal fast, Router.route!(routing_job(work_units: 30))
    end

    test 'legacy backends and agent servers both appear as routing candidates' do
      legacy = Backend.create!(name: 'Legacy box', connection_kind: 'legacy', base_url: 'http://legacy.test:8188',
                               enabled: true, last_check_ok: true)
      inv = inventory_for(@workflow)
      InventoryStore.store!(legacy, { 'hash' => 'legacy', 'models' => inv[:models], 'node_types' => inv[:node_types] })
      agent = create_agent_backend!(owner: @alice, visibility: 'public')
      bring_online_for!(agent, @workflow)

      names = Router.new(routing_job).candidates.map { it.backend.name }

      assert_includes names, legacy.name
      assert_includes names, agent.name
    end

    test 'second job uses legacy when the agent already has one queued' do
      legacy = Backend.create!(name: 'Legacy GPU', connection_kind: 'legacy', base_url: 'http://legacy.test:8188',
                               enabled: true, last_check_ok: true,
                               model_inventory: { 'checkpoints' => ['v1-5-pruned-emaonly-fp16.safetensors'] },
                               inventory_checked_at: Time.current)
      stub_request(:post, comfy_url(legacy, 'prompt')).to_return(body: { prompt_id: 'p-legacy' }.to_json)
      agent = create_agent_backend!(owner: @alice, visibility: 'public')
      bring_online_for!(agent, @workflow)

      first = routing_job

      assert_equal agent, Router.route!(first)

      assert_equal legacy, Router.route!(routing_job)
    end

    test 'legacy HTTP inventory refresh makes the admin backend routable' do
      legacy = Backend.create!(name: 'Shared GPU', connection_kind: 'legacy', base_url: 'http://legacy.test:8188',
                               enabled: true, last_check_ok: true)
      inv = inventory_for(@workflow)
      stub_inventory(legacy, { checkpoints: inv[:models]['checkpoints'] })
      stub_request(:get, comfy_url(legacy, 'object_info'))
        .to_return(body: inv[:node_types].index_with { {} }.to_json)

      assert legacy.refresh_inventory!
      assert_predicate legacy.backend_inventory, :present?

      agent = create_agent_backend!(owner: @alice, visibility: 'public')
      bring_online_for!(agent, @workflow)

      names = Router.new(routing_job).candidates.map { it.backend.name }

      assert_includes names, legacy.name
      assert_includes names, agent.name
    end
  end
end

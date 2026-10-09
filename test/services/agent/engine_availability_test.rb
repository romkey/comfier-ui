# frozen_string_literal: true

require 'test_helper'

module Agent
  class EngineAvailabilityTest < ActiveSupport::TestCase
    setup do
      @workflow = mflux_workflow!
      @backend = create_agent_backend!(owner: users(:alice))
    end

    test 'a Mac that runs mflux and has the model is ready' do
      bring_mac_online!(@backend, engines: { mflux: { models: %w[z-image-turbo] } })
      result = Availability.compute(@workflow, @backend.reload)

      assert_predicate result, :ready?
      assert_empty result.hints
    end

    test "a model the Mac hasn't downloaded yet is a hint, not a blocker" do
      bring_mac_online!(@backend, engines: { mflux: { models: [] } })
      result = Availability.compute(@workflow, @backend.reload)

      assert_predicate result, :ready?
      assert_match(/first run downloads it/, result.hints.first)
    end

    test 'a server without the engine is blocked' do
      bring_online!(@backend)
      result = Availability.compute(@workflow, @backend.reload)

      assert_predicate result, :blocked?
      assert_equal ["#{@backend.name} doesn't run mflux"], result.reasons
    end

    test 'a Mac with less memory than the recipe needs is blocked' do
      @workflow.update!(graph_json: @workflow.graph.merge('min_memory_gb' => 48).to_json)
      bring_mac_online!(@backend, engines: { mflux: { models: %w[z-image-turbo] } }, ram_gb: 32)
      result = Availability.compute(@workflow, @backend.reload)

      assert_predicate result, :blocked?
      assert_match(/needs about 48 GB/, result.reasons.first)
    end

    test 'legacy ComfyUI backends never run engine workflows' do
      legacy = Backend.create!(name: 'Old box', connection_kind: 'legacy', base_url: 'http://comfy.test:8188',
                               enabled: true)

      assert_equal ['Old box runs ComfyUI only'], Availability.compute(@workflow, legacy).reasons
    end
  end
end

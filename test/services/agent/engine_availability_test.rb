# frozen_string_literal: true

require 'test_helper'

module Agent
  class EngineAvailabilityTest < ActiveSupport::TestCase
    setup do
      @workflow = engine_workflow!
      @backend = create_agent_backend!(owner: users(:alice))
    end

    test 'a Mac that runs mflux and has the model is ready' do
      bring_mac_online!(@backend, engines: { mflux: { models: %w[z-image-turbo] } })
      result = Availability.compute(@workflow, @backend.reload)

      assert_predicate result, :ready?
      assert_empty result.hints
    end

    test "a model the Mac hasn't downloaded yet is a hint and a download, not a blocker" do
      bring_mac_online!(@backend, engines: { mflux: { models: [] } })
      result = Availability.compute(@workflow, @backend.reload)

      assert_predicate result, :ready?
      assert_match(/first run downloads it/, result.hints.first)
      assert_equal [{ 'folder' => 'mflux', 'filename' => 'z-image-turbo', 'engine' => 'mflux' }], result.models
    end

    test 'Wan 14B at 8 bits offers its repo for download and needs an agent that can load it' do
      workflow = engine_workflow!(name: 'Wan 14B', preset: 'wan-2.2-t2v-a14b-8bit', engine: 'mlx_video')
      bring_mac_online!(@backend, engines: { mlx_video: { models: [] } }, ram_gb: 96)
      result = Availability.compute(workflow, @backend.reload)

      assert_predicate result, :ready?
      assert_equal %w[SceneWorks/wan2.2-t2v-a14b-mlx], result.models.pluck('filename')

      @backend.update!(agent_version: '0.4.13')

      assert_match 'too old to load Wan models from Hugging Face',
                   Availability.compute(workflow, @backend).reasons.first
    end

    test 'Wan 14B at 8 bits needs 64 GB' do
      workflow = engine_workflow!(name: 'Wan 14B', preset: 'wan-2.2-t2v-a14b-8bit', engine: 'mlx_video')
      bring_mac_online!(@backend, engines: { mlx_video: { models: [] } }, ram_gb: 48)

      assert_match 'needs about 64 GB', Availability.compute(workflow, @backend.reload).reasons.first
    end

    test 'nothing is offered for download when the server does not allow downloads' do
      @backend.update!(model_downloads_enabled: false)
      bring_mac_online!(@backend, engines: { mflux: { models: [] } })
      @backend.update!(model_downloads_enabled: false)

      assert_empty Availability.compute(@workflow, @backend.reload).models
    end

    test 'a model downloaded a moment ago counts before the next inventory' do
      bring_mac_online!(@backend, engines: { mflux: { models: [] } })
      BackendModel.create!(backend: @backend, folder: 'mflux', filename: 'z-image-turbo')
      result = Availability.compute(@workflow, @backend.reload)

      assert_empty result.models
      assert_empty result.hints
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

    test 'an MLX video style is ready on a Mac with mlx-video, and hints until its repo is downloaded' do
      video = engine_workflow!(name: 'LTX', preset: 'ltx-2.3-distilled')
      bring_mac_online!(@backend, engines: { mlx_video: { models: [] } }, ram_gb: 128)
      result = Availability.compute(video, @backend.reload)

      assert_predicate result, :ready?
      assert_match(%r{prince-canuma/LTX-2.3-distilled and mlx-community/gemma-3-12b-it-bf16 aren't downloaded},
                   result.hints.first)
      assert_equal %w[prince-canuma/LTX-2.3-distilled mlx-community/gemma-3-12b-it-bf16],
                   result.models.pluck('filename')
      assert_predicate Availability.compute(@workflow, @backend), :blocked?
    end

    test 'an MLX video style asks only for the part that is missing' do
      video = engine_workflow!(name: 'LTX', preset: 'ltx-2.3-distilled')
      bring_mac_online!(@backend, engines: { mlx_video: { models: %w[prince-canuma/LTX-2.3-distilled] } },
                                  ram_gb: 128)

      assert_equal [EngineRecipe::LTX_TEXT_ENCODER],
                   Availability.compute(video, @backend.reload).models.pluck('filename')
    end

    test 'the memory check outlives the hello cache' do
      @workflow.update!(graph_json: @workflow.graph.merge('min_memory_gb' => 48).to_json)
      bring_mac_online!(@backend, engines: { mflux: { models: %w[z-image-turbo] } }, ram_gb: 32)
      Agent::Store.delete("hello:#{@backend.id}")

      assert_predicate Availability.compute(@workflow, @backend.reload), :blocked?
    end

    test 'a Mac that only runs MLX engines is never picked for ComfyUI styles' do
      bring_mac_online!(@backend, engines: { mflux: { models: [] } }, comfyui: false)
      result = Availability.compute(workflows(:sd_image), @backend.reload)

      assert_predicate result, :blocked?
      assert_includes result.reasons, "#{@backend.name} doesn't run ComfyUI"
    end
  end
end

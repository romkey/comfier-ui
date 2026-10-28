# frozen_string_literal: true

require 'test_helper'

module Agent
  class ModelOverridesTest < ActiveSupport::TestCase
    CHECKPOINT = 'v1-5-pruned-emaonly-fp16.safetensors'
    REPLACEMENT = 'v1-5-pruned-emaonly-q8.safetensors'

    setup do
      @alice = users(:alice)
      @workflow = workflows(:sd_image)
      backends(:gpu).update!(enabled: false)
      @backend = create_agent_backend!(owner: @alice)
      @socket = bring_online_for!(@backend, @workflow)
      @loader = @workflow.graph.find { |_id, node| node['class_type'] == 'CheckpointLoaderSimple' }.first
    end

    def override!(backend: @backend, **attrs)
      backend.model_overrides.create!({ folder: 'checkpoints', filename: CHECKPOINT, replacement_filename: REPLACEMENT,
                                        url: "https://huggingface.co/x/#{REPLACEMENT}", bytes: 2.gigabytes,
                                        sha256: 'c' * 64 }.merge(attrs))
    end

    def substitution(workflow = @workflow, backend: @backend) = ModelSubstitution.new(backend.reload, workflow)
    def needed(workflow = @workflow) = Requirements.for(workflow).models
    def compute = Availability.compute(@workflow, @backend.reload)

    # Reports the server's checkpoints as exactly these files.
    def report_checkpoints(*files)
      agent_inventory(@backend, models: { checkpoints: files }, node_types: inventory_for(@workflow)[:node_types])
    end

    test 'an override swaps the file in the models a server needs and in the graph it gets' do
      override!

      swapped = substitution.models(needed).map { it.values_at('filename', 'sha256', 'bytes', 'overrides') }

      assert_equal [[REPLACEMENT, 'c' * 64, 2.gigabytes, "checkpoints/#{CHECKPOINT}"]], swapped
      graph = substitution.rewrite(@workflow.graph, needed)

      assert_equal REPLACEMENT, graph.dig(@loader, 'inputs', 'ckpt_name')
      assert_equal @workflow.graph.except(@loader), graph.except(@loader)
    end

    test "a workflow's own override wins over the server's, and other servers keep the original" do
      other = Workflow.create!(name: 'SD copy', kind: 'image', graph_json: @workflow.graph.to_json)
      override!
      override!(workflow: @workflow, replacement_filename: 'sd15-for-this-style.safetensors')
      plain = create_agent_backend!(owner: @alice, name: 'Plain box')

      assert_equal ['sd15-for-this-style.safetensors'], substitution.models(needed).pluck('filename')
      assert_equal [REPLACEMENT], substitution(other).models(needed(other)).pluck('filename')
      assert_equal [CHECKPOINT], substitution(backend: plain).models(needed).pluck('filename')
    end

    test 'legacy servers ignore overrides' do
      override!(backend: backends(:gpu))

      assert_equal [CHECKPOINT], substitution(backend: backends(:gpu)).models(needed).pluck('filename')
    end

    test 'the replacement is what the server downloads, and the original no longer counts' do
      override!

      result = compute

      assert_predicate result, :needs_downloads?
      assert_equal([['checkpoints', REPLACEMENT, 'c' * 64]],
                   result.models.map { it.values_at('folder', 'filename', 'sha256') })

      report_checkpoints(REPLACEMENT)

      assert_predicate compute, :ready?
    end

    test 'a replacement without a link has to be on the server already' do
      override!(url: nil, bytes: nil, sha256: nil)

      assert_includes compute.reasons, "checkpoints/#{REPLACEMENT} (Agent box's override for " \
                                       "checkpoints/#{CHECKPOINT}) is missing and has no download link"
    end

    test "a GGUF replacement blocks the workflow when its node can't load GGUF files" do
      override!(replacement_folder: 'unet', replacement_filename: 'sd15-Q8_0.gguf')

      assert_match(/node 4 \(CheckpointLoaderSimple\) can't load GGUF files/, compute.reasons.join)
    end

    test 'a job names the replacement, in its folder, in the graph and the files it requires' do
      override!(replacement_folder: 'diffusion_models')
      gen = Generation.create!(user: @alice, workflow: @workflow, prompt: 'x', kind: :image, status: :queued,
                               backend: @backend, agent_state: 'queued', filled_workflow_json: @workflow.graph,
                               queued_at: Time.current, queue_order: Time.current.to_f)
      agent_request(@backend, 'r_1')

      assign = @socket.last_of_type('job.assign')

      assert_equal 'dispatched', gen.reload.agent_state
      assert_equal REPLACEMENT, assign.dig('workflow', @loader, 'inputs', 'ckpt_name')
      assert_equal({ 'diffusion_models' => [REPLACEMENT] }, assign.dig('requires', 'models'))
    end

    test 'on a Mac an fp8 replacement is converted like any fp8 file' do
      @backend.update!(system_json: { 'devices' => [{ 'type' => 'mps' }] })
      override!(replacement_filename: 'sd15_fp8_scaled.safetensors')

      assert_equal([['sd15_fp16_from_fp8.safetensors', 'fp8_to_fp16', "https://huggingface.co/x/#{REPLACEMENT}"]],
                   substitution.downloads(needed).map { it.values_at('filename', 'convert', 'url') })
    end

    test "a server's model actions see the replacement, not the original" do
      override!
      report_checkpoints(CHECKPOINT, REPLACEMENT)

      selection = ServerModels.for_workflow(@workflow, @backend.reload)

      assert_equal [REPLACEMENT], selection.installed.pluck('filename')
      assert_equal [REPLACEMENT], selection.downloads.pluck('filename')
    end

    def waiting_job
      report_checkpoints
      set_model_links(@workflow, url: "https://huggingface.co/x/#{CHECKPOINT}", bytes: 2.gigabytes)
      gen = Generation.create!(user: @alice, workflow: @workflow, prompt: 'x', kind: :image, status: :queued,
                               agent_state: 'routing', filled_workflow_json: @workflow.graph)
      gen.agent_transition!(from: 'routing', to: 'waiting_models', backend_id: @backend.id, queued_at: Time.current)
      DownloadPlanner.ensure_downloads!(@backend, compute.models, generation: gen, auto: true)
      gen
    end

    test 'a job waiting on downloads waits for the replacement once an override is saved' do
      gen = waiting_job

      override!

      assert_equal 'waiting_models', gen.reload.agent_state
      assert_includes ModelDownload.find_by!(backend: @backend, name: REPLACEMENT).for_generation_ids, gen.id
      assert_not_includes ModelDownload.find_by!(backend: @backend, name: CHECKPOINT).for_generation_ids, gen.id
    end

    test 'a waiting job runs right away when the replacement is already on the server' do
      gen = waiting_job
      report_checkpoints(REPLACEMENT)

      override!

      assert_includes %w[queued dispatched], gen.reload.agent_state
    end
  end
end

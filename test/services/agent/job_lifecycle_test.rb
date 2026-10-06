# frozen_string_literal: true

require 'test_helper'

module Agent
  class JobLifecycleTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @alice = users(:alice)
      @workflow = workflows(:sd_image)
      backends(:gpu).update!(enabled: false)
      @backend = create_agent_backend!(owner: @alice)
      @socket = bring_online_for!(@backend, @workflow)
    end

    def job_on(backend = @backend, state: 'dispatched', **attrs)
      Generation.create!({ user: @alice, workflow: @workflow, prompt: 'x', kind: :image, status: :running, backend:,
                           agent_state: state, agent_attempt: 1, filled_workflow_json: { '1' => {} },
                           structure_hash: 'sd15', dispatched_at: 1.minute.ago }.merge(attrs))
    end

    def uploaded_output(gen, backend: @backend)
      blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture('pixel.png').open, filename: 'out.png',
                                                    content_type: 'image/png')
      GenerationOutput.create!(upload_id: "u_#{SecureRandom.hex(8)}", generation: gen, backend:, node: '9',
                               filename: 'out.png', kind: 'image', mime: 'image/png', bytes: blob.byte_size,
                               storage_key: blob.key)
    end

    def event(type, gen, **fields) = agent_message(@backend, { 'type' => type, 'job_id' => job_id(gen) }.merge(fields))

    test 'accepted and progress move the job through its states' do
      gen = job_on
      event('job.accepted', gen)

      assert_equal 'accepted', gen.reload.agent_state
      assert_predicate gen, :running?

      event('job.progress', gen, phase: 'executing', progress: 0.4, node: '3')

      assert_equal 'running', gen.reload.agent_state
      assert_in_delta 0.4, gen.agent_progress

      event('job.progress', gen, phase: 'uploading', progress: 0.9)

      assert_equal 'uploading', gen.reload.agent_state
    end

    test 'completion attaches outputs and records the attempt' do
      gen = job_on(state: 'uploading')
      output = uploaded_output(gen)
      outputs = [{ 'upload_id' => output.upload_id, 'node' => '9', 'filename' => 'out.png' }]
      event('job.completed', gen, outputs:, timings: { 'execute_ms' => 12_000 })
      gen.reload

      assert_predicate gen, :succeeded?
      assert_equal 'completed', gen.agent_state
      assert_equal 1, gen.outputs.count
      assert_equal 'completed', gen.job_attempts.last.outcome
      assert_equal 1, PerfSample.where(backend: @backend).count
    end

    test 'duplicate and late events are harmless' do
      gen = job_on(state: 'accepted')
      event('job.accepted', gen)
      event('job.cancelled', gen)
      event('job.accepted', gen)

      assert_equal 'cancelled', gen.reload.agent_state
    end

    test 'a late accept takes back a job the ack timeout requeued' do
      gen = job_on
      travel(AgentTiming::ASSIGN_ACK_TIMEOUT_S + 1) { AssignAckTimeoutJob.perform_now(gen.id) }

      assert_equal 'queued', gen.reload.agent_state

      event('job.accepted', gen)

      assert_equal 'accepted', gen.reload.agent_state
      assert_predicate gen, :running?
    end

    test 'a requeued job the agent finished anyway completes' do
      gen = job_on(state: 'queued', dispatched_at: nil)
      output = uploaded_output(gen)
      outputs = [{ 'upload_id' => output.upload_id, 'node' => '9', 'filename' => 'out.png' }]
      event('job.completed', gen, outputs:)

      assert_equal 'completed', gen.reload.agent_state
      assert_equal 1, gen.outputs.count
    end

    def status_with(*gens, state: 'busy', accepting: false)
      jobs = gens.map { { 'job_id' => it.is_a?(String) ? it : job_id(it), 'state' => 'running', 'progress' => 0.2 } }
      agent_status(@backend, state:, accepting:, comfier_jobs: jobs)
    end

    test 'a status naming a job queued here takes it back as running' do
      gen = job_on(state: 'queued', dispatched_at: nil)
      waiting = job_on(state: 'queued', dispatched_at: nil)
      status_with(gen)
      gen.reload

      assert_equal 'running', gen.agent_state
      assert gen.running_at
      assert_in_delta 0.2, gen.agent_progress
      assert_empty @socket.of_type('job.cancel')

      agent_request(@backend)

      assert_equal 'queued', waiting.reload.agent_state
    end

    test 'a status naming an ended or moved job cancels it on the agent, once per interval' do
      ended = job_on(state: 'failed')
      moved = job_on(create_agent_backend!(owner: @alice, name: 'Other'), state: 'running')
      status_with(ended, moved, 'j_999999')
      status_with(ended, moved, 'j_999999')

      assert_equal [job_id(ended), job_id(moved), 'j_999999'], @socket.of_type('job.cancel').pluck('job_id')
      assert_equal 'running', moved.reload.agent_state

      travel(Agent::JobLifecycle::STRAY_CANCEL_EVERY_S + 1) { status_with(ended) }

      assert_equal 4, @socket.of_type('job.cancel').size
    end

    test 'an idle status still naming an old job is ignored' do
      requeued = job_on(state: 'queued', dispatched_at: nil)
      ended = job_on(state: 'failed')
      status_with(requeued, ended, state: 'idle', accepting: true)

      assert_equal 'queued', requeued.reload.agent_state
      assert_empty @socket.of_type('job.cancel')
    end

    test 'a status naming a job running here changes nothing' do
      gen = job_on(state: 'running')
      status_with(gen)

      assert_equal 'running', gen.reload.agent_state
      assert_empty @socket.of_type('job.cancel')
    end

    test 'events for another server are ignored' do
      other = create_agent_backend!(owner: @alice, name: 'Other')
      gen = job_on(other)
      event('job.accepted', gen)

      assert_equal 'dispatched', gen.reload.agent_state
    end

    test 'completion referencing an upload from another job fails the outputs stage' do
      gen = job_on(state: 'uploading')
      foreign = uploaded_output(job_on(state: 'completed'))
      event('job.completed', gen, outputs: [{ 'upload_id' => foreign.upload_id }])

      assert_equal 'outputs', gen.reload.job_attempts.last.reason
      assert_not_equal 'completed', gen.agent_state
    end

    test 'busy rejection requeues at the head of the same server' do
      gen = job_on
      event('job.rejected', gen, reason: 'busy')
      gen.reload

      assert_equal 'queued', gen.agent_state
      assert_equal @backend.id, gen.backend_id
      assert_operator gen.queue_order, :<, 0
    end

    test 'missing-model rejection refreshes inventory and reroutes elsewhere' do
      gen = job_on
      event('job.rejected', gen, reason: 'missing_models')
      gen.reload

      assert @socket.last_of_type('inventory.refresh')
      assert_includes gen.excluded_backend_ids, @backend.id
      assert_equal 'failed', gen.agent_state
      assert_equal Router::NO_SERVERS, gen.error_message
    end

    test 'invalid rejection fails with the detail' do
      gen = job_on
      event('job.rejected', gen, reason: 'invalid', detail: 'Bad graph')

      assert_equal 'Bad graph', gen.reload.error_message
    end

    test 'validation failures name the node' do
      gen = job_on(state: 'accepted')
      event('job.failed', gen, stage: 'validate', error: 'Prompt outputs failed validation',
                               node_errors: { '3' => { 'class_type' => 'KSampler',
                                                       'errors' => [{ 'message' => 'Required input is missing',
                                                                      'details' => 'seed' }] } })
      gen.reload

      assert_equal 'failed', gen.agent_state
      assert_equal 'Node 3 (KSampler): Required input is missing: seed', gen.error_message
      assert_equal 'validate', gen.error_json['stage']
    end

    test 'a model-list validation error reroutes once after an inventory refresh' do
      other = create_agent_backend!(owner: @alice, name: 'Other')
      bring_online_for!(other, @workflow)
      gen = job_on(state: 'accepted')
      event('job.failed', gen, stage: 'validate', error: 'invalid',
                               node_errors: { '4' => { 'errors' => [{ 'type' => 'value_not_in_list' }] } })
      gen.reload

      assert @socket.last_of_type('inventory.refresh')
      assert_equal other.id, gen.backend_id
      assert_equal 1, gen.agent_moves
    end

    test 'out of memory fails when no larger server exists' do
      gen = job_on(state: 'running')
      event('job.failed', gen, stage: 'execute', error: 'CUDA error: out of memory', exception_type: 'OutOfMemoryError')

      assert_equal JobLifecycle::OOM_MESSAGE, gen.reload.error_message
    end

    test 'out of memory moves to a server with more VRAM' do
      big = create_agent_backend!(owner: @alice, name: 'Big')
      bring_online_for!(big, @workflow)
      big.update!(vram_total: 48.gigabytes)
      gen = job_on(state: 'running')
      event('job.failed', gen, stage: 'execute', error: 'torch.OutOfMemoryError', node: '3')

      assert_equal big.id, gen.reload.backend_id
      assert_equal 'queued', gen.agent_state
    end

    test 'input failures retry within the budget, then fail' do
      gen = job_on(state: 'accepted')
      event('job.failed', gen, stage: 'inputs', error: 'HTTP 502')
      gen.reload

      assert_equal 'queued', gen.agent_state
      assert_operator gen.queue_order, :<, 0

      gen.update!(agent_state: 'accepted')
      event('job.failed', gen, stage: 'inputs', error: 'HTTP 502')
      gen.reload

      assert_equal 'failed', gen.agent_state
      assert_match "couldn't download this job's inputs", gen.error_message
    end

    test 'execution failures show the error and node' do
      gen = job_on(state: 'running')
      event('job.failed', gen, stage: 'execute', error: 'shape mismatch', node: '3', exception_type: 'RuntimeError')

      assert_equal 'shape mismatch (node 3, RuntimeError)', gen.reload.error_message
    end

    test 'cancelling a waiting job ends it at once' do
      gen = job_on(state: 'queued')

      assert JobLifecycle.cancel_by_user!(gen)
      assert_equal 'cancelled', gen.reload.agent_state
      assert_predicate gen, :cancelled?
    end

    test 'cancelling a job on the server waits for job.cancelled' do
      gen = job_on(state: 'running')
      JobLifecycle.cancel_by_user!(gen)

      assert_equal 'cancelling', gen.reload.agent_state
      assert_equal job_id(gen), @socket.last_of_type('job.cancel')['job_id']
      assert_enqueued_with(job: CancelTimeoutJob, args: [gen.id])

      event('job.cancelled', gen)

      assert_equal 'cancelled', gen.reload.agent_state
    end

    test 'an unconfirmed cancel times out' do
      gen = job_on(state: 'running')
      JobLifecycle.cancel_by_user!(gen)
      CancelTimeoutJob.perform_now(gen.id)

      assert_equal 'cancelled', gen.reload.agent_state
    end

    test 'a job completing while cancelling still completes' do
      gen = job_on(state: 'uploading')
      JobLifecycle.cancel_by_user!(gen)
      output = uploaded_output(gen)
      event('job.completed', gen, outputs: [{ 'upload_id' => output.upload_id }])

      assert_equal 'completed', gen.reload.agent_state
    end

    test 'the assign timeout requeues an unacknowledged job' do
      gen = job_on
      AssignAckTimeoutJob.perform_now(gen.id)

      assert_equal 'queued', gen.reload.agent_state
    end

    test 'an expired lease loses the running job and reroutes the rest' do
      other = create_agent_backend!(owner: @alice, name: 'Other')
      bring_online_for!(other, @workflow)
      running = job_on(state: 'running')
      queued = job_on(state: 'queued')
      Presence.mark_offline!(@backend, reason: 'disconnected')
      Hub.instance.disconnect!(@backend.id)
      Presence.record_disconnected!(@backend)

      travel (AgentTiming::LEASE_GRACE_S + 1).seconds do
        agent_status(other)
        LeaseSweepJob.perform_now
      end

      assert_equal other.id, running.reload.backend_id
      assert_equal 'lost', running.job_attempts.last.outcome
      assert_equal other.id, queued.reload.backend_id
    end

    test 'pinned jobs keep waiting through an expired lease' do
      queued = job_on(state: 'queued', pinned_backend_id: @backend.id)
      Presence.mark_offline!(@backend, reason: 'disconnected')

      travel (AgentTiming::LEASE_GRACE_S + 1).seconds do
        LeaseSweepJob.perform_now
      end

      assert_equal 'queued', queued.reload.agent_state
    end
  end
end

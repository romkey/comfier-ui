# frozen_string_literal: true

require 'test_helper'

module Agent
  class DispatcherTest < ActiveSupport::TestCase
    setup do
      @alice = users(:alice)
      @workflow = workflows(:sd_image)
      @backend = create_agent_backend!(owner: @alice)
      @socket = bring_online_for!(@backend, @workflow)
    end

    def queued_job(user: @alice, created_at: Time.current, **attrs)
      Generation.create!({ user:, workflow: @workflow, prompt: 'test', kind: :image, status: :queued,
                           backend: @backend, agent_state: 'queued', filled_workflow_json: { '1' => {} },
                           queued_at: created_at, queue_order: created_at.to_f, created_at: }.merge(attrs))
    end

    test 'job.request dispatches the first queued job' do
      gen = queued_job
      agent_request(@backend, 'r_1')

      gen.reload

      assert_equal 'dispatched', gen.agent_state
      assert_equal 'r_1', gen.dispatch_request_id
      assert_equal 1, gen.agent_attempt
      assign = @socket.last_of_type('job.assign')

      assert_equal job_id(gen), assign['job_id']
      assert_equal 'r_1', assign['request_id']
      assert_equal ['v1-5-pruned-emaonly-fp16.safetensors'], assign.dig('requires', 'models', 'checkpoints')
      assert_equal %w[3d], assign['previews']
      assert_nil OpenRequest.get(@backend.id)
    end

    test 'no job goes out without an open request' do
      gen = queued_job

      assert_not Dispatcher.dispatch_for!(@backend)
      assert_equal 'queued', gen.reload.agent_state
    end

    test 'one request gets one job even when dispatch runs twice' do
      2.times { queued_job }
      OpenRequest.set(@backend.id, 'r_2')

      assert Dispatcher.dispatch_for!(@backend, request_id: 'r_2')
      assert_not Dispatcher.dispatch_for!(@backend, request_id: 'r_2')
      assert_equal 1, @socket.of_type('job.assign').size
    end

    test 'status heartbeats keep an idle server request open past its expiry' do
      OpenRequest.set(@backend.id, 'r_idle')
      travel 50.minutes
      agent_status(@backend)
      travel 50.minutes

      assert_equal 'r_idle', OpenRequest.get(@backend.id)
    end

    test 'a stale request id does not dispatch' do
      queued_job
      OpenRequest.set(@backend.id, 'r_new')

      assert_not Dispatcher.dispatch_for!(@backend, request_id: 'r_old')
    end

    test 'nothing is dispatched while a job is on the server' do
      queued_job(agent_state: 'running')
      waiting = queued_job
      agent_request(@backend)

      assert_equal 'queued', waiting.reload.agent_state
    end

    test 'paused servers get nothing' do
      queued_job
      @backend.update!(paused: true)
      agent_request(@backend)

      assert_empty @socket.of_type('job.assign')
    end

    test 'waiting_models jobs are skipped' do
      waiting = queued_job(agent_state: 'waiting_models', created_at: 1.hour.ago)
      queued = queued_job
      agent_request(@backend)

      assert_equal 'dispatched', queued.reload.agent_state
      assert_equal 'waiting_models', waiting.reload.agent_state
    end

    test 'the owner goes first when owner priority is on, requeues before that' do
      @backend.update!(visibility: 'public')
      bobs = queued_job(user: users(:bob), created_at: 2.hours.ago)
      alices = queued_job(created_at: 1.hour.ago)

      assert_equal [alices, bobs], Dispatcher.ordered_queue(@backend).to_a

      bobs.update!(queue_order: bobs.created_at.to_f - 1e10)

      assert_equal [bobs, alices], Dispatcher.ordered_queue(@backend).to_a
    end

    test 'first come first served without owner priority' do
      @backend.update!(owner_priority: false, visibility: 'public')
      bobs = queued_job(user: users(:bob), created_at: 2.hours.ago)
      alices = queued_job(created_at: 1.hour.ago)

      assert_equal [bobs, alices], Dispatcher.ordered_queue(@backend).to_a
    end

    test 'status with accepting false voids the open request' do
      agent_request(@backend, 'r_3')
      agent_status(@backend, state: 'busy_local', accepting: false)

      assert_nil OpenRequest.get(@backend.id)
    end

    test 'three times p90 stretches the limit for styles that run long' do
      gen = queued_job(predicted_p90_ms: 30 * 60 * 1000)
      agent_request(@backend)

      assert_equal 90 * 60, @socket.last_of_type('job.assign')['timeout_s']
      assert_equal 'dispatched', gen.reload.agent_state
    end

    test 'a p90 estimate never shortens the limit for the kind' do
      @workflow.update_columns(kind: 'video') # rubocop:disable Rails/SkipsModelValidations
      gen = queued_job(predicted_p90_ms: 20 * 60 * 1000)
      agent_request(@backend)

      assert_equal 240 * 60, @socket.last_of_type('job.assign')['timeout_s']
      assert_equal 'dispatched', gen.reload.agent_state
    end

    test 'a time limit set on the workflow overrides the p90 estimate' do
      @workflow.update!(default_timeout_s: 4 * 3600)
      queued_job(predicted_p90_ms: 200_000)
      agent_request(@backend)

      assert_equal 4 * 3600, @socket.last_of_type('job.assign')['timeout_s']
    end

    test 'the p90 cap follows a kind limit raised past four hours' do
      AppSetting.current.update!(image_timeout_minutes: 6 * 60)
      queued_job(predicted_p90_ms: 2 * 3600 * 1000)
      agent_request(@backend)

      assert_equal 6 * 3600, @socket.last_of_type('job.assign')['timeout_s']
    end

    test 'the p90 estimate is capped at four hours under lower kind limits' do
      queued_job(predicted_p90_ms: 2 * 3600 * 1000)
      agent_request(@backend)

      assert_equal 4 * 3600, @socket.last_of_type('job.assign')['timeout_s']
    end

    test 'video jobs without an estimate get the video default' do
      @workflow.update_columns(kind: 'video') # rubocop:disable Rails/SkipsModelValidations
      queued_job
      agent_request(@backend)

      assert_equal 240 * 60, @socket.last_of_type('job.assign')['timeout_s']
    end

    test 'without a workflow limit the default follows the settings for the kind' do
      AppSetting.current.update!(image_timeout_minutes: 45)
      queued_job
      agent_request(@backend)

      assert_equal 45 * 60, @socket.last_of_type('job.assign')['timeout_s']
    end
  end
end

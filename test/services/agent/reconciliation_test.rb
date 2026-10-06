# frozen_string_literal: true

require 'test_helper'

module Agent
  class ReconciliationTest < ActiveSupport::TestCase
    setup do
      @alice = users(:alice)
      @workflow = workflows(:sd_image)
      @backend = create_agent_backend!(owner: @alice)
    end

    def job_on(state:, **attrs)
      Generation.create!({ user: @alice, workflow: @workflow, prompt: 'x', kind: :image, status: :running,
                           backend: @backend, agent_state: state, agent_attempt: 1, filled_workflow_json: { '1' => {} },
                           dispatched_at: 5.minutes.ago }.merge(attrs))
    end

    def reconnect!(active_jobs: [])
      socket = connect_agent!(@backend)
      agent_hello(@backend, active_jobs:)
      agent_inventory(@backend, **inventory_for(@workflow))
      agent_status(@backend)
      socket
    end

    test 'jobs the agent lists that are not its own are cancelled' do
      finished = job_on(state: 'completed')
      socket = reconnect!(active_jobs: [{ 'job_id' => job_id(finished), 'state' => 'running' },
                                        { 'job_id' => 'j_999999', 'state' => 'running' }])

      assert_equal [job_id(finished), 'j_999999'], socket.of_type('job.cancel').pluck('job_id')
    end

    test 'listed jobs adopt the reported state' do
      gen = job_on(state: 'dispatched')
      reconnect!(active_jobs: [{ 'job_id' => job_id(gen), 'state' => 'running' }])

      assert_equal 'running', gen.reload.agent_state
    end

    test 'a listed job requeued here while the agent ran it is taken back' do
      gen = job_on(state: 'queued', status: :queued, dispatched_at: nil)
      socket = reconnect!(active_jobs: [{ 'job_id' => job_id(gen), 'state' => 'running' }])

      assert_equal 'running', gen.reload.agent_state
      assert_empty socket.of_type('job.cancel')
    end

    test 'a listed job we were cancelling gets the cancel again' do
      gen = job_on(state: 'cancelling')
      socket = reconnect!(active_jobs: [{ 'job_id' => job_id(gen), 'state' => 'running' }])

      assert_equal [job_id(gen)], socket.of_type('job.cancel').pluck('job_id')
    end

    test 'after the wait, unlisted accepted jobs are lost and unlisted dispatched jobs requeued' do
      running = job_on(state: 'running')
      dispatched = job_on(state: 'dispatched')
      reconnect!
      Reconciliation.run!(@backend, hello_at: Time.current.to_f)

      assert_equal 'lost', running.reload.job_attempts.last.outcome
      assert_equal 'queued', dispatched.reload.agent_state
    end

    test 'jobs dispatched after the hello are left alone' do
      reconnect!
      hello_at = 1.second.ago.to_f
      fresh = job_on(state: 'dispatched', dispatched_at: Time.current)
      Reconciliation.run!(@backend, hello_at:)

      assert_equal 'dispatched', fresh.reload.agent_state
    end

    test 'jobs waiting for this server are routed when it returns' do
      @alice.update!(backend_affinity: 'mine_only')
      gen = Generation.create!(user: @alice, workflow: @workflow, prompt: 'x', kind: :image, status: :queued,
                               agent_state: 'routing', agent_phase: 'waiting_for_server', filled_workflow_json: {})
      reconnect!
      Reconciliation.run!(@backend)

      assert_equal @backend.id, gen.reload.backend_id
      assert_equal 'queued', gen.agent_state
    end

    test 'jobs pinned to a server route when inventory arrives after reconcile' do
      gen = Generation.create!(user: @alice, workflow: @workflow, prompt: 'x', kind: :image, status: :queued,
                               agent_state: 'routing', filled_workflow_json: { '1' => {} })
      gen.update_columns(pinned_backend_id: @backend.id, agent_phase: 'waiting_for_server') # rubocop:disable Rails/SkipsModelValidations
      connect_agent!(@backend)
      agent_hello(@backend)
      agent_status(@backend)
      Reconciliation.run!(@backend)

      assert_nil gen.reload.backend_id
      assert_equal 'waiting_for_server', gen.agent_phase

      agent_inventory(@backend, **inventory_for(@workflow))

      assert_equal @backend.id, gen.reload.backend_id
      assert_equal 'queued', gen.agent_state
      assert_nil gen.agent_phase
    end
  end
end

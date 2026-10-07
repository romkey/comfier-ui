# frozen_string_literal: true

require 'test_helper'

module Agent
  class PresenceTest < ActiveSupport::TestCase
    include ActionCable::TestHelper
    include ActiveJob::TestHelper

    setup { @backend = create_agent_backend!(owner: users(:alice)) }

    test 'offline with no connection' do
      assert_not Presence.online?(@backend)
      assert_equal 'offline', Presence.availability(@backend)
      assert_equal 'Offline', Presence.availability_label(@backend)
    end

    test 'hello records what the server is' do
      connect_agent!(@backend)
      agent_hello(@backend)
      @backend.reload

      assert_equal 'NVIDIA RTX 4090', @backend.gpu_name
      assert_equal 24.gigabytes, @backend.vram_total
      assert_equal '1.0.0', @backend.agent_version
      assert_equal 'NVIDIA RTX 4090', Presence.hello(@backend).dig('system', 'devices', 0, 'name')
    end

    test 'online after a status, with the reported state' do
      bring_online!(@backend, state: 'busy_local', accepting: false)

      assert Presence.online?(@backend)
      assert_equal 'In use locally', Presence.availability_label(@backend)
      assert_not Presence.accepting?(@backend)
    end

    test 'pause wins over what the agent reports' do
      bring_online!(@backend)
      @backend.update!(paused: true)

      assert_equal 'paused', Presence.availability(@backend)
      assert_not Presence.accepting?(@backend)
    end

    test 'a paused server is told so on hello' do
      @backend.update!(paused: true)
      socket = connect_agent!(@backend)
      agent_hello(@backend)

      assert socket.last_of_type('config.pause')
    end

    test 'offline once statuses stop' do
      bring_online!(@backend)
      travel (AgentTiming::OFFLINE_AFTER_S + 1).seconds do
        assert_not Presence.online?(@backend)
        OfflineSweepJob.perform_now

        assert_equal 'no_status', @backend.reload.offline_reason
        assert_predicate @backend.offline_since, :present?
      end
    end

    test 'bye goes offline at once' do
      bring_online!(@backend)
      agent_message(@backend, { 'type' => 'bye', 'reason' => 'shutdown' })

      assert_not Presence.online?(@backend)
      assert_equal 'shutdown', @backend.reload.offline_reason
    end

    test 'hello clears the offline marker' do
      @backend.update!(offline_since: 1.hour.ago, offline_reason: 'disconnected')
      bring_online!(@backend)

      assert_nil @backend.reload.offline_since
    end

    test 'a status after a gap clears the offline marker so the lease grace starts over' do
      bring_online!(@backend)
      gen = Generation.create!(user: users(:alice), workflow: workflows(:sd_image), prompt: 'x', kind: :video,
                               status: :running, backend: @backend, agent_state: 'running', agent_attempt: 1,
                               filled_workflow_json: { '1' => {} }, dispatched_at: Time.current)
      start = Time.current
      travel_to(start + AgentTiming::OFFLINE_AFTER_S + 1) do
        OfflineSweepJob.perform_now
        agent_status(@backend, state: 'busy', accepting: false)

        assert_nil @backend.reload.offline_since
      end
      # Hours later, one late status must not cost the job its lease straight away.
      travel_to(start + 2.hours) do
        OfflineSweepJob.perform_now
        LeaseSweepJob.perform_now

        assert_equal 'running', gen.reload.agent_state
      end
    end

    test 'job progress keeps a busy server online while its status is late' do
      bring_online!(@backend, state: 'busy', accepting: false)
      start = Time.current
      travel_to(start + 20.seconds) do
        agent_message(@backend,
                      { 'type' => 'job.progress', 'job_id' => 'j_0', 'phase' => 'running', 'progress' => 0.2 })
      end
      travel_to(start + AgentTiming::OFFLINE_AFTER_S + 10) do
        assert Presence.online?(@backend)
        assert_equal 'busy', Presence.agent_state(@backend)
      end
    end

    test 'job progress does not bring back a server that already went offline' do
      bring_online!(@backend)
      travel_to(Time.current + AgentTiming::OFFLINE_AFTER_S + 1) do
        agent_message(@backend,
                      { 'type' => 'job.progress', 'job_id' => 'j_0', 'phase' => 'running', 'progress' => 0.2 })

        assert_not Presence.online?(@backend)
      end
    end

    test 'status is persisted at most every 30 seconds' do
      bring_online!(@backend, state: 'idle')
      agent_status(@backend, state: 'busy')

      assert_equal 'idle', @backend.reload.last_status_json['state']
      travel 31.seconds do
        agent_status(@backend, state: 'busy')

        assert_equal 'busy', @backend.reload.last_status_json['state']
      end
    end

    test 'broadcasts are debounced to one a second per server' do
      bring_online!(@backend)
      broadcasts = -> { enqueued_jobs.count { it['job_class'] == 'Turbo::Streams::ActionBroadcastJob' } }
      travel 2.seconds do
        clear_enqueued_jobs
        3.times { agent_status(@backend) }

        assert_equal 2, broadcasts.call, 'one presence and one status-cell replace'
      end
      travel 4.seconds do
        agent_status(@backend)

        assert_equal 4, broadcasts.call
      end
    end

    test 'the free-disk figure is the smallest reported' do
      bring_online!(@backend, disk_free: { 'models' => 50.gigabytes, 'output' => 20.gigabytes })

      assert_equal 20.gigabytes, Presence.disk_free(@backend)
    end
  end
end

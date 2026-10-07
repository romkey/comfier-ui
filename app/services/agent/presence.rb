# frozen_string_literal: true

module Agent
  # Where each agent server stands right now. The web process writes it on every hello and
  # status; any process can read it. A server is online while its presence key is fresh, which
  # expires OFFLINE_AFTER_S after the last status.
  class Presence
    LABELS = {
      'offline' => 'Offline', 'paused' => 'Paused', 'error' => 'Error', 'busy_local' => 'In use locally',
      'busy' => 'Busy', 'idle' => 'Available', 'starting' => 'Starting', 'disk_low' => 'Low on disk'
    }.freeze

    class << self
      def record_connected!(backend)
        Store.write_json("connected:#{backend.id}", { 'at' => Time.current.iso8601 })
        Store.write_json("presence:#{backend.id}", { 'state' => 'starting', 'at' => Time.current.iso8601 },
                         ttl: AgentTiming::OFFLINE_AFTER_S)
      end

      def record_disconnected!(backend)
        Store.delete("connected:#{backend.id}")
        OpenRequest.clear(backend.id)
      end

      def record_status!(backend, status)
        Store.write_json("presence:#{backend.id}", status.merge('at' => Time.current.iso8601),
                         ttl: AgentTiming::OFFLINE_AFTER_S)
      end

      # Job progress means the agent is alive even when its status is late (it waits on ComfyUI,
      # which can be slow mid-step). Only extends a presence that hasn't expired yet.
      def touch!(backend)
        current = status(backend)
        record_status!(backend, current) if current
      end

      def record_hello!(backend, hello)
        Store.write_json("hello:#{backend.id}", hello, ttl: 1.day)
      end

      def hello(backend) = Store.read_json("hello:#{backend.id}")

      def status(backend) = Store.read_json("presence:#{backend.id}")

      def connected?(backend) = Store.read_json("connected:#{backend.id}").present?

      def online?(backend)
        backend.agent? && connected?(backend) && status(backend).present?
      end

      def agent_state(backend)
        return 'offline' unless online?(backend)

        status(backend)['state'].presence || 'starting'
      end

      # The state users see, with frontend pause taking precedence over what the agent reports.
      def availability(backend)
        return 'offline' unless online?(backend)
        return 'paused' if backend.paused?

        agent_state(backend)
      end

      def availability_label(backend) = LABELS.fetch(availability(backend)) { availability(backend).humanize }

      def accepting?(backend)
        online?(backend) && !backend.paused? && status(backend)['accepting'] != false
      end

      def disk_free(backend)
        disk = status(backend)&.dig('disk_free')
        case disk
        when Hash then disk.values.grep(Numeric).min
        when Numeric then disk
        end
      end

      def vram_free(backend) = status(backend)&.dig('vram_free')

      def publish!(backend, force: false)
        return unless force || Store.once_per?("broadcast:#{backend.id}", ttl: 1)

        PresenceBroadcaster.broadcast(backend)
      end

      def mark_offline!(backend, reason:)
        Store.delete("presence:#{backend.id}")
        backend.update_columns(offline_since: Time.current, offline_reason: reason) # rubocop:disable Rails/SkipsModelValidations
        publish!(backend, force: true)
      end
    end
  end
end

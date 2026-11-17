module Metrics
  module Sections
    # The servers that run generations. Per-server series are labelled with the server's name.
    class Servers < Base
      def collect
        @backends = Backend.kept.ordered.includes(:backend_speed).to_a
        summary
        info
        flags
        capacity
        workload
      end

      private

      def each_server = @backends.map { |backend| [{ server: backend.name }, yield(backend)] }

      def agents = @backends.select(&:agent?)

      # Stricter than Backend#online?, which gives a legacy server that was never checked the benefit of the doubt.
      def up?(backend) = backend.agent? ? Agent::Presence.online?(backend) : backend.last_check_ok == true

      def summary
        counts = @backends.group_by { [it.connection_kind, it.visibility] }
        gauge('comfier_servers', 'Servers, by how they connect and who may use them.',
              counts.map { |(connection_kind, visibility), list| [{ connection_kind:, visibility: }, list.size] })
        gauge('comfier_servers_online', 'Servers that are reachable now.', @backends.count { up?(it) })
      end

      def info
        gauge('comfier_server_info', 'Details of a server. Always 1.', @backends.map do |backend|
          [{ server: backend.name, connection_kind: backend.connection_kind, visibility: backend.visibility,
             gpu: backend.gpu_name.to_s, agent_version: backend.agent_version.to_s,
             comfyui_version: backend.comfyui_version.to_s }, 1]
        end)
      end

      def flags
        gauge('comfier_server_up', 'Whether the server is reachable: an agent is connected and reporting, or a ' \
                                   'legacy server passed its last check.', each_server { up?(it) })
        gauge('comfier_server_enabled', 'Whether the server is enabled.', each_server(&:enabled))
        gauge('comfier_server_paused', 'Whether the server is paused.', each_server(&:paused))
        gauge('comfier_server_state', 'The state of an agent server; the series for its current state is 1.',
              agents.map { [{ server: it.name, state: Agent::Presence.availability(it) }, 1] })
        gauge('comfier_server_last_seen_timestamp_seconds', 'When the server was last heard from or checked.',
              each_server { (it.last_seen_at || it.last_checked_at)&.to_f })
      end

      def capacity
        gauge('comfier_server_vram_total_bytes', 'GPU memory the server has.', each_server(&:vram_total))
        gauge('comfier_server_vram_free_bytes', 'GPU memory free on an online agent server.',
              agents.map { [{ server: it.name }, numeric(Agent::Presence.vram_free(it))] })
        gauge('comfier_server_disk_free_bytes', 'Free disk space on an online agent server (its fullest model disk).',
              agents.map { [{ server: it.name }, numeric(Agent::Presence.disk_free(it))] })
        gauge('comfier_server_speed_index', 'Measured speed against a typical server: 1 is typical, 2 twice as slow.',
              each_server(&:speed_index))
      end

      def workload
        running = Generation.in_progress.where.not(backend_id: nil).group(:backend_id).count
        gauge('comfier_server_generations_in_progress', 'Generations assigned to the server and not finished.',
              each_server { running.fetch(it.id, 0) })
        downloads = ModelDownload.active.group(:backend_id).count
        gauge('comfier_server_model_downloads_active', 'Model downloads queued or running on the server.',
              each_server { downloads.fetch(it.id, 0) })
      end

      def numeric(value) = value.is_a?(Numeric) ? value : nil
    end
  end
end

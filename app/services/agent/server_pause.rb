# frozen_string_literal: true

module Agent
  # When a server is paused, waiting jobs should not sit on it. Pinned jobs and mine-only owners
  # park in routing until the server resumes; everyone else is routed elsewhere.
  module ServerPause
    ON_PAUSE = %w[queued waiting_models].freeze

    module_function

    def reroute_jobs!(backend)
      backend.generations.where(agent_state: ON_PAUSE).includes(:user).find_each { park_or_reroute!(backend, it) }
    end

    # Jobs parked while this server was paused (or offline) try routing again once it accepts work.
    def route_waiting!(backend)
      Generation.where(agent_state: 'routing', agent_phase: 'waiting_for_server')
                .where('pinned_backend_id = :id OR user_id = :owner', id: backend.id, owner: backend.owner_user_id)
                .find_each { JobLifecycle.route!(it) }
    end

    def park_or_reroute!(backend, gen)
      policy = BackendPolicy.new(gen.user)
      if gen.pinned_backend_id == backend.id ||
         (policy.affinity == 'mine_only' && backend.owned_by?(gen.user))
        park_for_resume!(gen)
        return
      end

      DownloadPlanner.release_generation!(gen) if gen.agent_state == 'waiting_models'
      JobLifecycle.reroute!(gen, exclude: backend, from: ON_PAUSE)
    end

    def park_for_resume!(gen)
      DownloadPlanner.release_generation!(gen) if gen.agent_state == 'waiting_models'
      gen.agent_transition!(from: ON_PAUSE, to: 'routing', backend_id: nil, queued_at: nil,
                            agent_phase: 'waiting_for_server')
    end
  end
end

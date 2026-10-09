# frozen_string_literal: true

module Agent
  # Turns styles on and off per server. Jobs for a style that was just turned off and are still
  # waiting on that server route again; ones already running there finish.
  module ServerStyles
    WAITING = ServerPause::ON_PAUSE

    module_function

    # Returns true when the setting changed.
    def set!(backend, workflow, enabled:)
      return false unless backend.set_workflow_enabled!(workflow, enabled)

      reroute_jobs!(backend, workflow) unless enabled
      true
    end

    # Jobs waiting on a server for an engine it no longer reports (say mflux was uninstalled) would never be
    # claimed there, so they route again, elsewhere.
    def reroute_unsupported_engines!(backend)
      supported = Workflow.where(engine: backend.engines.keys).select(:id)
      backend.generations.where(agent_state: WAITING).where.not(workflow_id: nil)
             .where.not(workflow_id: supported).find_each do |gen|
        DownloadPlanner.release_generation!(gen) if gen.agent_state == 'waiting_models'
        JobLifecycle.reroute!(gen, exclude: backend, from: WAITING)
      end
    end

    # The router skips servers that don't run the style, so pinned jobs fail with that reason.
    def reroute_jobs!(backend, workflow)
      backend.generations.where(workflow_id: workflow.id, agent_state: WAITING).find_each do |gen|
        DownloadPlanner.release_generation!(gen) if gen.agent_state == 'waiting_models'
        JobLifecycle.reroute!(gen, exclude: nil, from: WAITING)
      end
    end
  end
end

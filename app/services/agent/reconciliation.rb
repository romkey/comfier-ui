# frozen_string_literal: true

module Agent
  # What happens when an agent (re)connects. Immediately: cancel jobs it lists that aren't its
  # any more, and adopt the state of the ones that are. After RECONCILE_WAIT_S (time for buffered
  # terminal events to arrive): jobs we think it has but it didn't list are lost or requeued.
  # Then downloads are resent and jobs waiting for this server are routed.
  class Reconciliation
    PHASE_STATES = { 'inputs' => 'accepted', 'queued' => 'accepted', 'running' => 'running',
                     'uploading' => 'uploading' }.freeze

    def self.on_hello!(backend, hello)
      new(backend).on_hello!(hello)
      ReconcileBackendJob.set(wait: AgentTiming::RECONCILE_WAIT_S.seconds).perform_later(backend.id, Time.current.to_f)
    end

    def self.run!(backend, hello_at: nil) = new(backend).run!(hello_at:)

    def initialize(backend)
      @backend = backend
    end

    def on_hello!(hello)
      Array(hello['active_jobs']).each { reconcile_listed(it) }
      DownloadLifecycle.reconcile_listed!(@backend, Array(hello['active_downloads']))
    end

    def run!(hello_at: nil)
      hello = Presence.hello(@backend)
      return unless hello && Presence.connected?(@backend)

      listed = Array(hello['active_jobs']).filter_map { GenerationAgent.id_from_job_id(it['job_id']) }
      stale = @backend.generations.agent_on_server.where.not(id: listed)
      stale = stale.where(dispatched_at: ...Time.zone.at(hello_at)) if hello_at
      stale.find_each { unlisted!(it) }
      DownloadSender.resend_unlisted!(@backend, Array(hello['active_downloads']))
      DownloadSender.flush_queue!(@backend)
      route_waiting!
      RebalanceJob.perform_later
    end

    private

    def reconcile_listed(entry)
      id = GenerationAgent.id_from_job_id(entry['job_id'])
      gen = id && Generation.find_by(id:)
      return cancel_stray(entry['job_id']) unless on_this_server?(gen)
      return if gen.agent_state == 'cancelling' && cancel_stray(entry['job_id'])

      target = PHASE_STATES[entry['state']] || 'running'
      return if [target, 'uploading'].include?(gen.agent_state)

      gen.agent_transition!(from: gen.agent_state, to: target)
    end

    def on_this_server?(gen) = gen.present? && gen.backend_id == @backend.id && gen.agent_on_server?

    def cancel_stray(job_id)
      Commands.send_message(@backend.id, { 'type' => 'job.cancel', 'job_id' => job_id.to_s })
    end

    # Dispatched but never accepted: the assign was lost with the connection, so just requeue.
    def unlisted!(gen)
      if gen.agent_state == 'dispatched'
        JobLifecycle.requeue_head!(gen, from: 'dispatched')
      else
        JobLifecycle.lost!(gen)
      end
    end

    # Jobs parked in `routing` because this user's servers were offline, or pinned here.
    def route_waiting! = ServerPause.route_waiting!(@backend)
  end
end

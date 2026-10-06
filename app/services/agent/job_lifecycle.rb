# frozen_string_literal: true

module Agent
  # Job events from agents and the frontend's own transitions (cancel, lost, requeue). Every state
  # change is a compare-and-set, so duplicated or late events are harmless.
  module JobLifecycle # rubocop:disable Metrics/ModuleLength
    ON_SERVER = Generation::ON_SERVER_STATES
    # Back in this server's queue after a late or lost job.accepted, though the agent may be running it.
    RECLAIMABLE = %w[queued dispatched].freeze
    # The agent may keep running these; anything else it reports should be cancelled.
    KEEP_ON_AGENT = (ON_SERVER - %w[cancelling] + RECLAIMABLE).freeze
    STRAY_CANCEL_EVERY_S = 15
    OOM = /OutOfMemory|out of memory|CUDA error: out of memory/i
    MODEL_NOT_IN_LIST = /value_not_in_list|not in list|not in \[/i
    OOM_MESSAGE = 'The server ran out of GPU memory. Try a smaller size or fewer frames.'
    LOST_MESSAGE = 'The server went offline while running this job.'
    STAGE_MESSAGES = {
      'inputs' => "The server couldn't download this job's inputs: %s",
      'outputs' => "The server couldn't upload the results: %s"
    }.freeze

    module_function

    def find(backend, job_id)
      id = GenerationAgent.id_from_job_id(job_id)
      id && Generation.find_by(id:, backend_id: backend.id)
    end

    def accepted!(backend, message)
      gen = find(backend, message['job_id'])
      return unless gen

      adopt!(gen, 'accepted')
      Warmth.job_started!(backend)
    end

    def rejected!(backend, message)
      gen = find(backend, message['job_id'])
      return unless gen && %w[dispatched accepted].include?(gen.agent_state)

      reason = message['reason'].to_s
      record_attempt!(gen, backend, 'rejected', reason:)
      case reason
      when 'busy', 'shutting_down' then requeue_head!(gen, from: %w[dispatched accepted])
      when 'invalid' then fail!(gen, message['detail'].presence || "#{backend.name} couldn't read this workflow.")
      else
        Commands.send_message(backend.id, { 'type' => 'inventory.refresh' }) if reason.start_with?('missing')
        reroute!(gen, exclude: backend)
      end
    end

    def progress!(backend, message)
      gen = reclaim(find(backend, message['job_id']))
      return unless gen && %w[accepted running uploading].include?(gen.agent_state)

      advance_phase!(gen, message['phase'] == 'uploading' ? 'uploading' : 'running')
      gen.update_columns(agent_phase: message['phase'], agent_progress: message['progress'].to_f.clamp(0, 1), # rubocop:disable Rails/SkipsModelValidations
                         current_node: message['node'])
      gen.broadcast_replace_later_to([gen.user, :generations]) if Store.once_per?("progress:#{gen.id}", ttl: 1)
      Timeline.schedule(backend)
    end

    def completed!(backend, message)
      gen = reclaim(find(backend, message['job_id']))
      return unless gen && ON_SERVER.include?(gen.agent_state)

      outputs, missing = uploaded_outputs(gen, backend, message)
      return missing_outputs!(backend, message, missing) if missing.any?

      return unless gen.agent_transition!(from: ON_SERVER, to: 'completed', agent_phase: nil, agent_progress: 1.0,
                                          error_message: nil)

      Outputs.attach!(gen, outputs)
      finish_attempt!(gen, backend, 'completed', timings: message['timings'])
      Warmth.job_finished!(backend, gen.model_set_hash)
      LoadMinute.job_completed!(backend)
      after_job!(backend, gen)
    end

    def failed!(backend, message)
      gen = reclaim(find(backend, message['job_id']))
      return unless gen && ON_SERVER.include?(gen.agent_state)

      stage = message['stage'].to_s
      gen.update_columns(error_json: failure_details(message)) # rubocop:disable Rails/SkipsModelValidations
      infra = %w[inputs outputs].include?(stage)
      record_attempt!(gen, backend, 'failed', reason: stage, infra:, timings: message['timings'])
      handle_failure(gen, backend, stage, message, infra)
      after_job!(backend, gen)
    end

    def cancelled!(backend, message)
      gen = find(backend, message['job_id'])
      return unless gen

      if gen.agent_transition!(from: ON_SERVER, to: 'cancelled', error_message: Generation::CANCELLED_MESSAGE,
                               agent_phase: nil)
        record_attempt!(gen, backend, 'cancelled')
      end
      after_job!(backend, gen)
    end

    # The agent says it has this job, in a hello or a status. Requeued here though the agent was
    # running it: take it back. Cancelling, ended or now another server's: tell the agent to cancel.
    # `target` (from a hello) also moves an accepted or running job to the agent's phase.
    def reported_active!(backend, job_id, target: nil)
      gen = find(backend, job_id)
      state = gen&.agent_state
      return cancel_stray!(backend, job_id) if KEEP_ON_AGENT.exclude?(state)
      return reported_reclaim!(backend, gen, target || 'running') if RECLAIMABLE.include?(state)
      return if target.nil? || [target, 'uploading'].include?(state)

      gen.agent_transition!(from: state, to: target)
    end

    def reported_reclaim!(backend, gen, target)
      from = gen.agent_state
      return unless adopt!(gen, target)

      Rails.logger.info("[Agent] backend #{backend.id} is running #{gen.agent_job_id}; took it back from #{from}")
      Timeline.schedule(backend)
      Presence.publish!(backend)
    end

    def cancel_stray!(backend, job_id)
      return unless Store.once_per?("stray_cancel:#{backend.id}:#{job_id}", ttl: STRAY_CANCEL_EVERY_S)

      Commands.send_message(backend.id, { 'type' => 'job.cancel', 'job_id' => job_id.to_s })
    end

    # Queued or dispatched here, and the agent says it accepted or is running it.
    def adopt!(gen, target)
      now = Time.current
      attrs = { accepted_at: gen.accepted_at || now, dispatched_at: gen.dispatched_at || now }
      attrs[:running_at] = now if target == 'running' && gen.running_at.nil?
      gen.agent_transition!(from: RECLAIMABLE, to: target, **attrs)
    end

    # An event for a job requeued here after its job.accepted went missing: the agent ran it anyway.
    def reclaim(gen)
      adopt!(gen, 'running') if gen && RECLAIMABLE.include?(gen.agent_state)
      gen
    end

    # The frontend asked to cancel. Waiting jobs end now; jobs on a server wait for its
    # job.cancelled, or for CancelTimeoutJob.
    def cancel_by_user!(gen)
      if gen.agent_transition!(from: Generation::WAITING_STATES, to: 'cancelled',
                               error_message: Generation::CANCELLED_MESSAGE)
        DownloadPlanner.release_generation!(gen)
        return true
      end
      return false unless gen.agent_transition!(from: %w[dispatched accepted running uploading], to: 'cancelling',
                                                cancel_requested_at: Time.current)

      Commands.send_message(gen.backend_id, { 'type' => 'job.cancel', 'job_id' => gen.agent_job_id })
      CancelTimeoutJob.set(wait: AgentTiming::CANCEL_TIMEOUT_S.seconds).perform_later(gen.id)
      true
    end

    # The server went away while the job was on it.
    def lost!(gen, reason: 'lost')
      backend = gen.backend
      return unless ON_SERVER.include?(gen.agent_state)
      return finish_cancel!(gen) if gen.agent_state == 'cancelling'

      record_attempt!(gen, backend, 'lost', reason:, infra: true)
      if retry_budget?(gen)
        requeue_elsewhere!(gen, from: ON_SERVER)
      else
        fail!(gen, LOST_MESSAGE, from: ON_SERVER)
      end
      Timeline.schedule(backend) if backend
    end

    def finish_cancel!(gen)
      gen.agent_transition!(from: 'cancelling', to: 'cancelled', error_message: Generation::CANCELLED_MESSAGE)
    end

    # Back to the head of the same server's queue (the agent was busy or restarting).
    def requeue_head!(gen, from:)
      gen.agent_transition!(from:, to: 'queued', dispatched_at: nil, dispatch_request_id: nil, accepted_at: nil,
                            queue_order: gen.created_at.to_f - 1e10)
      Dispatcher.dispatch_for!(gen.backend) if gen.backend
    end

    # Route again, to any server (the previous one may come back), at the head of its queue.
    def requeue_elsewhere!(gen, from:)
      return unless gen.agent_transition!(from:, to: 'routing', backend_id: nil, dispatched_at: nil,
                                          dispatch_request_id: nil, accepted_at: nil, running_at: nil,
                                          agent_progress: 0, agent_phase: nil)

      route!(gen, head: true)
    end

    def reroute!(gen, exclude:, from: %w[dispatched accepted running uploading], **router_options)
      gen.excluded_backend!(exclude.id) if exclude
      return unless gen.agent_transition!(from:, to: 'routing', backend_id: nil, dispatched_at: nil,
                                          dispatch_request_id: nil, accepted_at: nil, running_at: nil,
                                          agent_progress: 0, agent_phase: nil,
                                          agent_moves: gen.agent_moves + 1)

      route!(gen, head: true, **router_options)
    end

    def route!(gen, **)
      Router.route!(gen, **)
    rescue Router::UnroutableError => e
      fail!(gen, e.message, from: 'routing')
    end

    def fail!(gen, message, from: Generation::WAITING_STATES + ON_SERVER)
      gen.agent_transition!(from:, to: 'failed', error_message: message.to_s.truncate(1000), agent_phase: nil)
    end

    def retry_budget?(gen) = gen.job_attempts.infra.count <= AgentTiming::MAX_INFRA_RETRIES

    def handle_failure(gen, backend, stage, message, infra)
      if stage == 'validate' && retry_after_refresh?(gen, message)
        gen.job_attempts.order(:id).last.update!(reason: 'validate_models')
        Commands.send_message(backend.id, { 'type' => 'inventory.refresh' })
        reroute!(gen, exclude: backend)
      elsif stage == 'execute' && oom?(message)
        oom!(gen, backend)
      elsif infra && retry_budget?(gen)
        requeue_elsewhere!(gen, from: ON_SERVER)
      else
        fail!(gen, failure_message(stage, message), from: ON_SERVER)
      end
    end

    def oom!(gen, backend)
      larger = gen.job_attempts.count <= GenerationAgent::MAX_ATTEMPTS &&
               BackendPolicy.new(gen.user).usable_agent_backends.where('vram_total > ?', backend.vram_total.to_i)
                            .any? { Presence.online?(it) }
      return fail!(gen, OOM_MESSAGE, from: ON_SERVER) unless larger

      reroute!(gen, exclude: backend, min_vram: backend.vram_total.to_i)
      fail!(gen, OOM_MESSAGE, from: 'routing') if gen.reload.agent_state == 'routing'
    end

    # A model the server should have wasn't in ComfyUI's list: refresh its inventory and try elsewhere, once.
    def retry_after_refresh?(gen, message)
      model_list_error?(message) && gen.job_attempts.where(reason: 'validate_models').none?
    end

    def advance_phase!(gen, target)
      return if gen.agent_state == target

      attrs = target == 'running' && gen.running_at.nil? ? { running_at: Time.current } : {}
      gen.agent_transition!(from: gen.agent_state, to: target, **attrs)
    end

    # The outputs a completion names that this server uploaded for this job, and any it didn't.
    def uploaded_outputs(gen, backend, message)
      upload_ids = Array(message['outputs']).filter_map { it['upload_id'] }
      outputs = gen.generation_outputs.where(upload_id: upload_ids, backend_id: backend.id)
      [outputs, upload_ids - outputs.pluck(:upload_id)]
    end

    def missing_outputs!(backend, message, missing)
      failed!(backend, message.merge('stage' => 'outputs', 'error' => "Missing outputs: #{missing.to_sentence}"))
    end

    def oom?(message) = [message['error'], message['exception_type']].join(' ').match?(OOM)

    def model_list_error?(message) = message['node_errors'].to_json.match?(MODEL_NOT_IN_LIST)

    def failure_message(stage, message)
      case stage
      when 'validate'
        errors = format_node_errors(message['node_errors'])
        errors.presence || message['error'].to_s
      when 'execute' then execute_failure_message(message)
      else format(STAGE_MESSAGES.fetch(stage, '%s'), message['error'].to_s)
      end
    end

    # "shape mismatch (node 3, RuntimeError)"
    def execute_failure_message(message)
      text = message['error'].presence || 'The workflow failed'
      return text if message['node'].blank?

      where = ["node #{message['node']}", message['exception_type'].presence].compact.join(', ')
      "#{text} (#{where})"
    end

    # "Node 7 (KSampler): Value not in list: sampler_name"
    def format_node_errors(node_errors)
      return '' unless node_errors.is_a?(Hash)

      node_errors.flat_map do |node_id, info|
        errors = Array(info.is_a?(Hash) ? info['errors'] : nil)
        label = "Node #{node_id}#{" (#{info['class_type']})" if info.is_a?(Hash) && info['class_type']}"
        errors.map { "#{label}: #{[it['message'], it['details']].compact_blank.join(': ')}" }
      end.join("\n")
    end

    def failure_details(message)
      message.slice('stage', 'error', 'node', 'exception_type', 'node_errors', 'traceback_tail').compact
    end

    # details: reason:, infra:, timings:
    def record_attempt!(gen, backend, outcome, **details)
      JobAttempt.create!(generation: gen, backend:, attempt: gen.agent_attempt, outcome:, reason: details[:reason],
                         infra: details.fetch(:infra, false), timings_json: details[:timings] || {}, warm: gen.warm,
                         predicted_execute_ms: gen.predicted_total_ms, started_at: gen.accepted_at || gen.dispatched_at,
                         ended_at: Time.current)
    end

    def finish_attempt!(gen, backend, outcome, timings:)
      attempt = record_attempt!(gen, backend, outcome, timings:)
      Perf::Recorder.record!(gen, backend, attempt, timings)
      maybe_rebalance!(gen, timings)
    end

    # A job that took far longer or shorter than predicted shifts everyone's estimates.
    def maybe_rebalance!(gen, timings)
      predicted = gen.predicted_total_ms.to_i
      actual = timings.is_a?(Hash) ? timings['execute_ms'].to_i : 0
      return unless predicted.positive? && actual.positive?
      return unless actual > predicted * 2 || actual < predicted / 2

      RebalanceJob.perform_later
    end

    def after_job!(backend, gen)
      Dispatcher.dispatch_for!(backend)
      Timeline.schedule(backend)
      Presence.publish!(backend)
      gen
    end
  end
end

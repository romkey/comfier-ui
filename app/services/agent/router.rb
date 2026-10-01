# frozen_string_literal: true

module Agent
  # Picks where a job should run: the eligible legacy backend or agent server with the earliest
  # predicted finish (backlog, downloads, then the job). Ties go to the user's own server, then
  # the lower recent failure rate, then the shorter queue.
  class Router # rubocop:disable Metrics/ClassLength
    class UnroutableError < StandardError
      attr_reader :reasons

      def initialize(reasons, message = nil)
        @reasons = reasons
        super(message || Router.explain(reasons))
      end
    end

    Candidate = Data.define(:backend, :availability, :prediction, :finish_at, :tiebreak)
    NO_SERVERS = 'No servers you can use are online.'
    WAITING_FOR_OWN = 'Waiting for your server to come online'
    UNAVAILABLE = %w[offline starting paused].freeze

    def self.route!(generation, **) = new(generation, **).route!

    def self.explain(reasons)
      return NO_SERVERS if reasons.empty? || reasons.values.all? { UNAVAILABLE.include?(it) }

      "No server can run this job. #{reasons.map { |name, reason| "#{name}: #{reason}" }.join('; ')}"
    end

    # min_vram: only servers with more VRAM than this (for out-of-memory retries).
    # only: consider just this backend (rebalancing).
    def initialize(generation, head: false, min_vram: nil, only: nil)
      @generation = generation
      @user = generation.user
      @workflow = generation.workflow
      @policy = BackendPolicy.new(@user)
      @head = head
      @min_vram = min_vram
      @only = only
    end

    # Returns the chosen backend, nil when the job should wait in `routing`, or raises.
    def route!
      candidates, reasons = evaluate
      return wait_for_own_server!(reasons) if candidates.empty? && wait_for_own_server?(reasons)
      raise UnroutableError, reasons if candidates.empty?

      chosen = candidates.min_by { [it.finish_at.to_f.round, *it.tiebreak] }
      assign!(chosen)
      chosen.backend
    end

    # Every eligible server, scored, for rebalancing and the studio estimate.
    def candidates = evaluate.first

    private

    def evaluate
      reasons = {}
      candidates = pool.filter_map do |backend|
        availability = Availability.compute(@workflow, backend)
        reason = ineligible_reason(backend, availability)
        reasons[backend.name] = reason if reason
        score(backend, availability) unless reason
      end
      [candidates, reasons]
    end

    def pool
      restricted = restricted_pool
      return restricted unless restricted.nil?

      combined = @policy.runnable_backends.includes(:backend_speed, :backend_inventory).to_a
      combined.reject! { |b| b.agent? && b.paused? }
      combined.reject! { @generation.excluded_backend_ids.include?(it.id) }
      with_affinity(combined)
    end

    def restricted_pool
      return only_pool if @only
      return pinned_pool if @generation.pinned_backend_id

      nil
    end

    def only_pool = backend_runnable?(@only) ? [@only] : []

    def pinned_pool
      pinned = Backend.find_by(id: @generation.pinned_backend_id)
      pinned && backend_runnable?(pinned) ? [pinned] : []
    end

    def with_affinity(backends)
      case @policy.affinity
      when 'mine_only' then backends.select { it.agent? && it.owned_by?(@user) }
      else backends
      end
    end

    def backend_runnable?(backend)
      return false unless @policy.can_use?(backend)
      return false if backend.agent? && backend.paused?
      return false if @generation.excluded_backend_ids.include?(backend.id)

      true
    end

    def ineligible_reason(backend, availability)
      state_reason(backend) || fit_reason(backend) || availability_reason(backend, availability)
    end

    def state_reason(backend)
      if backend.legacy?
        return 'offline' if backend.last_check_ok == false

        return nil
      end

      return 'offline' unless Presence.online?(backend)
      return 'starting' unless backend.backend_inventory

      'paused' if backend.paused?
    end

    def fit_reason(backend)
      return "doesn't run the #{@workflow.name} style" unless backend.allows_workflow?(@workflow)
      return 'not enough GPU memory' if backend.agent? && @min_vram && backend.vram_total.to_i <= @min_vram

      'queue limit for other users reached' if backend.agent? && over_queue_limit?(backend)
    end

    def over_queue_limit?(backend)
      return false if backend.owned_by?(@user)

      backend.generations.agent_waiting.where(user_id: @user.id).where.not(id: @generation.id).count >=
        backend.max_queued_per_other_user
    end

    def availability_reason(_backend, availability)
      return availability.reasons.first(3).join('; ') if availability.blocked?
      return missing_models_reason(availability) if availability.needs_downloads?

      nil
    end

    def missing_models_reason(availability)
      names = availability.models.map { "#{it['folder']}/#{it['filename']}" }.first(3).join(', ')
      "missing models (#{names.presence || 'required files'})"
    end

    def score(backend, availability)
      prediction = Perf::Predictor.predict(@generation, backend)
      start = [backlog_end(backend), download_eta(backend, availability)].max
      Candidate.new(backend:, availability:, prediction:, finish_at: start + (prediction.total_ms / 1000.0),
                    tiebreak: [backend.owned_by?(@user) ? 0 : 1, failure_rate(backend), queue_length(backend)])
    end

    def backlog_end(backend)
      backend.legacy? ? legacy_backlog_end(backend) : Timeline.backlog_end(backend)
    end

    def legacy_backlog_end(backend)
      clock = Time.current
      backend.generations.where(status: :running, agent_state: nil).order(:submitted_at).find_each do |gen|
        clock += legacy_remaining_s(gen)
      end
      backend.generations.where(status: :queued, agent_state: nil, backend_id: backend.id)
             .order(:created_at).find_each do |gen|
        clock += (gen.predicted_total_ms || 60_000) / 1000.0
      end
      clock
    end

    def legacy_remaining_s(gen)
      ms = gen.predicted_total_ms || 60_000
      return ms / 1000.0 unless gen.running_at

      elapsed_ms = (Time.current - gen.running_at) * 1000
      [(ms - elapsed_ms) / 1000.0, 5].max
    end

    def download_eta(backend, availability)
      return Time.current unless availability.needs_downloads?

      bytes = availability.total_bytes || 5.gigabytes
      host = URI.parse(availability.models.first['url'].to_s).host.to_s
      bps = Perf::Transfers.download_bps(backend, host) || Perf::Transfers::DEFAULT_BPS['download']
      Time.current + (bytes / bps)
    rescue URI::InvalidURIError
      5.minutes.from_now
    end

    def failure_rate(backend)
      recent = backend.job_attempts.where(created_at: 7.days.ago..)
      total = recent.count
      total.zero? ? 0.0 : (recent.failures.count.to_f / total).round(2)
    end

    def queue_length(backend)
      if backend.legacy?
        backend.generations.where(status: %w[queued running], agent_state: nil).count
      else
        backend.generations.agent_waiting.count + backend.generations.agent_on_server.count
      end
    end

    def wait_for_own_server?(reasons)
      return false if reasons.empty?

      (@generation.pinned_backend_id || @policy.affinity == 'mine_only') &&
        reasons.values.all? { UNAVAILABLE.include?(it) }
    end

    def wait_for_own_server!(_reasons)
      @generation.update_columns(agent_phase: 'waiting_for_server', backend_id: nil) # rubocop:disable Rails/SkipsModelValidations
      nil
    end

    def assign!(candidate)
      return assign_legacy!(candidate) if candidate.backend.legacy?

      assign_agent!(candidate)
    end

    def assign_agent!(candidate)
      backend = candidate.backend
      attrs = prediction_attrs(candidate)
      if candidate.availability.needs_downloads?
        return unless @generation.agent_transition!(from: 'routing', to: 'waiting_models', **attrs)

        DownloadPlanner.ensure_downloads!(backend, candidate.availability.models, generation: @generation, auto: true)
      else
        return unless @generation.agent_transition!(from: 'routing', to: 'queued', **attrs)

        Dispatcher.dispatch_for!(backend)
      end
      Timeline.schedule(backend)
    end

    def assign_legacy!(candidate)
      backend = candidate.backend
      @generation.update!(prediction_attrs(candidate).merge(
                            backend_id: backend.id, queued_at: Time.current, queue_order: queue_order, agent_phase: nil
                          ))
      Backends::LegacyRunner.new.submit_to(@generation, backend)
    end

    def prediction_attrs(candidate)
      { backend_id: candidate.backend.id, queued_at: Time.current, queue_order: queue_order, agent_phase: nil,
        predicted_total_ms: candidate.prediction.total_ms, predicted_p90_ms: candidate.prediction.p90_ms,
        prediction_confidence: candidate.prediction.confidence,
        prediction_source: candidate.prediction.source, warm: candidate.prediction.warm }
    end

    # Requeued jobs go ahead of everything else but keep their original order among themselves.
    def queue_order
      created = @generation.created_at.to_f
      @head ? created - 1e10 : Time.current.to_f
    end
  end
end

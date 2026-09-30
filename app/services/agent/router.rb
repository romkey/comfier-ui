# frozen_string_literal: true

module Agent
  # Picks the agent server a job should run on: the eligible server with the earliest predicted
  # finish (its backlog, any downloads, then the job itself). Ties go to the user's own server,
  # then the lower recent failure rate, then the shorter queue.
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
      scope = @policy.usable_agent_backends.where(paused: false).includes(:backend_speed, :backend_inventory)
      scope = scope.where.not(id: @generation.excluded_backend_ids) if @generation.excluded_backend_ids.any?
      return scope.where(id: @only.id).to_a if @only
      return scope.where(id: @generation.pinned_backend_id).to_a if @generation.pinned_backend_id

      with_affinity(scope.to_a)
    end

    def with_affinity(backends)
      case @policy.affinity
      when 'mine_only' then backends.select { it.owned_by?(@user) }
      when 'prefer_mine'
        own = backends.select { it.owned_by?(@user) && Presence.online?(it) && !it.paused? }
        own.any? ? own : backends
      else backends
      end
    end

    def ineligible_reason(backend, availability)
      state_reason(backend) || fit_reason(backend) || availability_reason(backend, availability)
    end

    def state_reason(backend)
      return 'offline' unless Presence.online?(backend)
      return 'starting' unless backend.backend_inventory

      'paused' if backend.paused?
    end

    def fit_reason(backend)
      return "doesn't run the #{@workflow.name} style" unless backend.allows_workflow?(@workflow)
      return 'not enough GPU memory' if @min_vram && backend.vram_total.to_i <= @min_vram

      'queue limit for other users reached' if over_queue_limit?(backend)
    end

    def over_queue_limit?(backend)
      return false if backend.owned_by?(@user)

      backend.generations.agent_waiting.where(user_id: @user.id).where.not(id: @generation.id).count >=
        backend.max_queued_per_other_user
    end

    def availability_reason(backend, availability)
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
      start = [Timeline.backlog_end(backend), download_eta(backend, availability)].max
      Candidate.new(backend:, availability:, prediction:, finish_at: start + (prediction.total_ms / 1000.0),
                    tiebreak: [backend.owned_by?(@user) ? 0 : 1, failure_rate(backend), queue_length(backend)])
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

    def queue_length(backend) = backend.generations.agent_waiting.count

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
      backend = candidate.backend
      attrs = { backend_id: backend.id, queued_at: Time.current, queue_order: queue_order, agent_phase: nil,
                predicted_total_ms: candidate.prediction.total_ms, predicted_p90_ms: candidate.prediction.p90_ms,
                prediction_confidence: candidate.prediction.confidence,
                prediction_source: candidate.prediction.source, warm: candidate.prediction.warm }
      if candidate.availability.needs_downloads?
        return unless @generation.agent_transition!(from: 'routing', to: 'waiting_models', **attrs)

        DownloadPlanner.ensure_downloads!(backend, candidate.availability.models, generation: @generation, auto: true)
      else
        return unless @generation.agent_transition!(from: 'routing', to: 'queued', **attrs)

        Dispatcher.dispatch_for!(backend)
      end
      Timeline.schedule(backend)
    end

    # Requeued jobs go ahead of everything else but keep their original order among themselves.
    def queue_order
      created = @generation.created_at.to_f
      @head ? created - 1e10 : Time.current.to_f
    end
  end
end

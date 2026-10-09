# frozen_string_literal: true

module Agent
  # Answers an agent's open job.request with the next queued job. Runs in any process: the open
  # request lives in the store, and a per-backend advisory lock plus a compare-and-set update keep
  # two processes from sending two jobs against one request.
  class Dispatcher
    ACTIVE = %w[dispatched accepted running uploading cancelling].freeze
    LOCK_NAMESPACE = 7_401
    P90_TIMEOUT_CAP_S = 4 * 3600

    def self.dispatch_for!(backend, request_id: nil) = new(backend, request_id:).dispatch!

    # Queued jobs in the order they'll run: requeues first (negative queue_order), then the owner's
    # jobs when owner priority is on, then first come first served.
    def self.ordered_queue(backend, states: %w[queued])
      scope = backend.generations.where(agent_state: states)
      if backend.owner_priority? && backend.owner_user_id
        scope = scope.order(Arel.sql('CASE WHEN queue_order < 0 THEN 0 ELSE 1 END'))
                     .order(Arel.sql(ActiveRecord::Base.sanitize_sql_array(
                                       ['CASE WHEN generations.user_id = ? THEN 0 ELSE 1 END', backend.owner_user_id]
                                     )))
      end
      scope.agent_dispatch_order
    end

    def self.base_url
      return ENV['APP_URL'].chomp('/') if ENV['APP_URL'].present?

      options = Rails.application.routes.default_url_options
      return 'http://localhost:3000' if options[:host].blank?

      port = ":#{options[:port]}" if options[:port]
      "#{options[:protocol] || 'http'}://#{options[:host]}#{port}"
    end

    def initialize(backend, request_id: nil)
      @backend = backend
      @request_id = request_id
    end

    def dispatch!
      return false if @backend.paused? || !Presence.connected?(@backend)

      job, request_id = claim
      return false unless job

      Commands.send_message(@backend.id, assign_message(job, request_id))
      AssignAckTimeoutJob.set(wait: AgentTiming::ASSIGN_ACK_TIMEOUT_S.seconds).perform_later(job.id)
      Timeline.schedule(@backend)
      true
    end

    private

    def claim
      Generation.transaction do
        Generation.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{@backend.id.to_i})")
        request_id = OpenRequest.get(@backend.id)
        next if request_id.blank? || (@request_id && @request_id != request_id)
        next if Generation.exists?(backend_id: @backend.id, agent_state: ACTIVE)

        job = runnable(self.class.ordered_queue(@backend)).first
        next unless job&.agent_transition!(from: 'queued', to: 'dispatched', dispatched_at: Time.current,
                                           dispatch_request_id: request_id,
                                           agent_attempt: job.agent_attempt + 1)

        OpenRequest.clear(@backend.id)
        [job, request_id]
      end
    end

    # Routing already sends jobs only to servers that run their engine; this guards against a server
    # that stopped reporting one since.
    def runnable(queue)
      supported = Workflow.where(engine: @backend.engines.keys).select(:id)
      queue.merge(Generation.where(workflow_id: nil).or(Generation.where(workflow_id: supported)))
    end

    def assign_message(job, request_id)
      return engine_assign_message(job, request_id) unless job.workflow.nil? || job.workflow.comfyui?

      requirements = Requirements.for(job.workflow)
      {
        'type' => 'job.assign', 'request_id' => request_id, 'job_id' => job.agent_job_id,
        'workflow' => job.filled_workflow_json,
        'inputs' => job.generation_inputs.map { input_entry(job, it) },
        'upload_url' => "#{base_url}/api/agent/jobs/#{job.agent_job_id}/outputs",
        'requires' => {
          'node_types' => requirements.node_types,
          'models' => requirements.models.group_by { it['folder'] }.transform_values { |ms| ms.pluck('filename') }
        },
        'timeout_s' => timeout_s(job),
        'previews' => %w[3d]
      }
    end

    # mflux and MLX video jobs: the filled recipe stands in for the graph, and the agent checks nothing up front.
    def engine_assign_message(job, request_id)
      {
        'type' => 'job.assign', 'request_id' => request_id, 'job_id' => job.agent_job_id,
        'engine' => job.workflow.engine, 'workflow' => job.filled_workflow_json,
        'inputs' => job.generation_inputs.map { input_entry(job, it) },
        'upload_url' => "#{base_url}/api/agent/jobs/#{job.agent_job_id}/outputs",
        'requires' => {}, 'timeout_s' => timeout_s(job)
      }
    end

    def input_entry(job, input)
      { 'id' => input.input_id, 'url' => "#{base_url}/api/agent/jobs/#{job.agent_job_id}/inputs/#{input.input_id}",
        'filename' => input.filename, 'bytes' => input.bytes }.compact
    end

    # A time limit set on the workflow wins. Otherwise the limit for the job's kind (Settings → Time
    # limits), which 3 × p90 can stretch for styles that usually run long, up to four hours or the
    # kind's limit if that's higher. The estimate never shortens the limit an admin set.
    def timeout_s(job)
      default = job.agent_timeout_s
      return default if job.workflow&.default_timeout_s.present?

      computed = (3 * job.predicted_p90_ms.to_i / 1000.0).round
      computed.clamp(default, [P90_TIMEOUT_CAP_S, default].max)
    end

    def base_url = Dispatcher.base_url
  end
end

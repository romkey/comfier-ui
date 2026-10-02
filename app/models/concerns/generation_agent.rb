# Lifecycle of a generation that runs on an agent server. `agent_state` is the detailed state;
# `status` stays the coarse queued/running/succeeded/failed the rest of the app understands.
module GenerationAgent
  extend ActiveSupport::Concern

  AGENT_STATES = %w[routing queued waiting_models dispatched accepted running uploading cancelling
                    completed failed cancelled].freeze
  WAITING_STATES = %w[routing queued waiting_models].freeze
  ON_SERVER_STATES = %w[dispatched accepted running uploading cancelling].freeze
  TERMINAL_STATES = %w[completed failed cancelled].freeze
  MAX_ATTEMPTS = 3
  MAX_MOVES = 3

  STATUS_FOR = {
    'routing' => :queued, 'queued' => :queued, 'waiting_models' => :queued, 'dispatched' => :queued,
    'accepted' => :running, 'running' => :running, 'uploading' => :running, 'cancelling' => :running,
    'completed' => :succeeded, 'failed' => :failed, 'cancelled' => :failed
  }.freeze

  included do
    has_many :job_attempts, dependent: :delete_all
    has_many :prediction_logs, dependent: :delete_all

    validates :agent_state, inclusion: { in: AGENT_STATES }, allow_nil: true
    validate :pinned_backend_usable, if: -> { pinned_backend_id.present? && will_save_change_to_pinned_backend_id? }

    scope :agent_waiting, -> { where(agent_state: WAITING_STATES) }
    scope :agent_on_server, -> { where(agent_state: ON_SERVER_STATES) }
    scope :agent_active, -> { where(agent_state: WAITING_STATES + ON_SERVER_STATES) }
    scope :agent_dispatch_order, -> { order(Arel.sql('queue_order ASC NULLS LAST, created_at ASC, id ASC')) }
  end

  def agent_job? = agent_state.present?
  def agent_job_id = "j_#{id}"
  def agent_waiting? = WAITING_STATES.include?(agent_state)
  def agent_on_server? = ON_SERVER_STATES.include?(agent_state)
  def agent_terminal? = TERMINAL_STATES.include?(agent_state)

  def self.id_from_job_id(job_id) = job_id.to_s[/\Aj_(\d+)\z/, 1]&.to_i

  def excluded_backend_ids = Array(super).map(&:to_i)

  # Moves agent_state from one of `from` to `to` only if nobody else changed it first, then saves
  # the coarse status and `attrs` normally so notifications and broadcasts fire. Returns true when
  # this caller won.
  def agent_transition!(from:, to:, **attrs)
    won = self.class.transaction do
      next false unless self.class.where(id:, agent_state: Array(from))
                            .update_all(agent_state: to, updated_at: Time.current).positive? # rubocop:disable Rails/SkipsModelValidations

      reload
      assign_attributes(attrs.merge(status: STATUS_FOR.fetch(to)))
      if TERMINAL_STATES.include?(to)
        self.completed_at ||= Time.current
        self.last_terminal_at = Time.current
      end
      save!(validate: false)
    end
    return false unless won

    after_agent_terminal if TERMINAL_STATES.include?(to)
    true
  end

  def excluded_backend!(backend_id)
    self.class.where(id:).update_all( # rubocop:disable Rails/SkipsModelValidations
      ['excluded_backend_ids = excluded_backend_ids || ?::jsonb', [backend_id].to_json]
    )
    reload
  end

  def agent_timeout_s = workflow&.default_timeout_s || (self.class.timeout / 1.second).to_i

  STATUS_LINES = { 'routing' => 'Finding a server', 'waiting_models' => 'Waiting for models to download',
                   'uploading' => 'Saving results', 'cancelling' => 'Cancelling' }.freeze

  # A short human line for where the job is, shown under the status pill.
  def agent_status_line
    case agent_state
    when 'queued' then queued_line
    when 'dispatched' then "Sent to #{backend&.name}"
    when 'accepted' then "Starting on #{backend&.name}"
    when 'running' then running_line
    else STATUS_LINES[agent_state]
    end
  end

  private

  def pinned_backend_usable
    backend = Backend.find_by(id: pinned_backend_id)
    return unless backend

    if workflow
      reason = StudioServerPin.new(workflow, user).block_reason(backend)
      errors.add(:pinned_backend_id, reason) if reason
    elsif !BackendPolicy.new(user).can_use?(backend)
      errors.add(:pinned_backend_id, "isn't a server you can use")
    end
  end

  def queued_line
    return 'Waiting for a server' unless backend

    "Waiting for #{backend.name}"
  end

  def running_line
    percent = (agent_progress.to_f * 100).round
    [agent_phase&.humanize || 'Running', ("#{percent}%" if percent.positive?)].compact.join(' · ')
  end

  def after_agent_terminal
    Agent::Uploads.cleanup_after_run(self) if user.delete_uploads_after_run?
  end
end

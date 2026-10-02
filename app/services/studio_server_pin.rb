# Which servers appear in the studio "Run on" picker and whether the user may pin a job to them.
# Servers the user can run on are always listed; ones that cannot run the current workflow yet
# (missing models, offline, and so on) stay visible but disabled.
class StudioServerPin
  Choice = Data.define(:backend, :label, :selectable, :html_options)

  def initialize(workflow, user)
    @workflow = workflow
    @user = user
  end

  def choices
    backends = BackendPolicy.new(@user).runnable_backends.includes(:owner_user).to_a
    availability = WorkflowAvailability.where(workflow_id: @workflow.id, backend_id: backends.map(&:id))
                                       .index_by(&:backend_id)
    backends.map { build_choice(it, availability[it.id]) }
  end

  def show_picker? = choices.many? || choices.any? { !it.selectable }

  def pinnable?(backend) = block_reason(backend).nil?

  def block_reason(backend, availability_record = nil)
    return unless backend

    policy = BackendPolicy.new(@user)
    return "isn't a server you can use" unless policy.can_use?(backend)
    return "doesn't run this style" unless backend.allows_workflow?(@workflow)

    state_reason(backend) || model_availability_reason(backend, availability_record)
  end

  private

  def build_choice(backend, record)
    reason = block_reason(backend, record)
    label = reason ? "#{display_name(backend)} — #{reason}" : display_name(backend)
    html_options = reason ? { disabled: 'disabled' } : {}
    Choice.new(backend:, label:, selectable: reason.nil?, html_options:)
  end

  def display_name(backend)
    backend.owned_by?(@user) ? "#{backend.name} (yours)" : backend.name
  end

  def state_reason(backend)
    if backend.legacy?
      return 'offline' if backend.last_check_ok == false

      return nil
    end

    return 'offline' unless Agent::Presence.online?(backend)
    return 'starting' unless backend.backend_inventory
    return 'paused' if backend.paused?

    nil
  end

  def model_availability_reason(backend, record)
    result = availability_result(backend, record)
    return nil if result.ready?
    return 'models not installed yet' if missing_models_for_job?(result)

    Array(result.reasons).first.to_s.truncate(72).presence || 'missing required models'
  end

  def missing_models_for_job?(result)
    return true if result.needs_downloads?
    return false unless result.blocked?

    Array(result.reasons).any? { |reason| reason.match?(/missing|isn't installed|isn't available on/) }
  end

  def availability_result(backend, record)
    record ? availability_from_record(record) : Agent::Availability.compute(@workflow, backend)
  end

  def availability_from_record(record)
    Agent::Availability::Result.new(
      status: record.status.to_sym,
      models: Array(record.details['models']),
      total_bytes: record.details['total_bytes'],
      reasons: Array(record.details['reasons']),
      hints: Array(record.details['hints'])
    )
  end
end

# Agent servers: the list of servers a user can use, registering one, its live page, and its
# settings. Owners and admins manage; anyone it's shared with can see it.
class ServersController < ApplicationController # rubocop:disable Metrics/ClassLength
  before_action :set_policy
  before_action :set_backend, except: %i[index new create]
  before_action :require_view, only: %i[show load performance]
  before_action :require_manage, only: %i[edit update destroy setup pause resume]

  rate_limit to: 5, within: 1.hour, only: :create, by: -> { current_user.id },
             with: -> { redirect_to servers_path, alert: 'You registered several servers just now. Try again later.' }

  def index
    @backends = @policy.listable_backends.includes(:owner_user, :backend_speed).ordered.to_a
    @workflows = Workflow.enabled.ordered.to_a
    @availability = WorkflowAvailability.where(backend_id: @backends.map(&:id)).group_by(&:backend_id)
  end

  def show
    @can_manage = @policy.can_manage?(@backend)
    @queue = Agent::Dispatcher.ordered_queue(@backend, states: Generation::WAITING_STATES).includes(:user,
                                                                                                    :workflow).limit(50)
    @current = @backend.generations.agent_on_server.includes(:user, :workflow).first
    @downloads = @backend.model_downloads.agent.recent.limit(20)
    @workflows = Workflow.enabled.ordered.to_a
    @availability = @backend.workflow_availabilities.index_by(&:workflow_id)
    @perf_stats = @backend.perf_stats.includes(:workflow).order(n: :desc) if @can_manage
    @keys = @backend.backend_keys.recent if @can_manage
  end

  def new
    return redirect_to(servers_path, alert: "Registering servers isn't turned on.") unless @policy.can_register?

    @backend = Backend.new(connection_kind: 'agent', visibility: 'private')
  end

  def edit; end

  def create
    return head :forbidden unless @policy.can_register?

    @backend = Backend.new(server_params.merge(connection_kind: 'agent', owner_user: current_user))
    if @backend.save
      if (share_alert = unknown_emails_alert(sync_shares!))
        flash.now[:alert] = share_alert
      end
      @new_key = @backend.issue_agent_key!
      audit(:server_registered, "Registered server #{@backend.name}")
      audit(:server_key_created, "Created a key for #{@backend.name}")
      render :setup, status: :created
    else
      render :new, status: :unprocessable_content
    end
  end

  def setup; end

  def update
    before = @backend.attributes.slice(*policy_attributes)
    if @backend.update(server_params)
      if (share_alert = unknown_emails_alert(sync_shares!))
        flash[:alert] = share_alert
      end
      audit_policy_changes(before)
      redirect_to settings_server_path(@backend), notice: 'Saved.', status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    name = @backend.name
    Agent::ServerRemoval.call(@backend)
    audit(:server_deleted, "Deleted server #{name}")
    redirect_to servers_path, notice: "Deleted #{name}. Its history is kept.", status: :see_other
  end

  def pause = change_pause(true)

  def resume = change_pause(false)

  def load
    render json: ServerCharts.new(@backend).load(range: params[:range])
  end

  def performance
    render json: ServerCharts.new(@backend).performance
  end

  private

  def set_policy
    @policy = BackendPolicy.new(current_user)
  end

  def set_backend
    @backend = Backend.agent.kept.find(params[:id])
  end

  def require_view
    head :not_found unless @policy.can_manage?(@backend) || @policy.can_use?(@backend)
  end

  def require_manage
    head :not_found unless @policy.can_manage?(@backend)
  end

  def change_pause(paused)
    @backend.update!(paused:)
    Agent::Commands.send_message(@backend.id, { 'type' => paused ? 'config.pause' : 'config.resume' })
    if paused
      Agent::ServerPause.reroute_jobs!(@backend)
    else
      Agent::ServerPause.route_waiting!(@backend)
      Agent::Dispatcher.dispatch_for!(@backend)
    end
    Agent::Presence.publish!(@backend, force: true)
    audit(paused ? :server_paused : :server_resumed, "#{paused ? 'Paused' : 'Resumed'} #{@backend.name}")
    redirect_back_or_to server_path(@backend), status: :see_other
  end

  def policy_attributes
    %w[visibility owner_priority max_queued_per_other_user allowed_workflow_ids auto_download_policy]
  end

  def server_params
    permitted = params.expect(backend: [:name, :description, :visibility, :owner_priority, :max_queued_per_other_user,
                                        :auto_download_policy, { allowed_workflow_ids: [] }])
    if permitted.key?(:allowed_workflow_ids)
      permitted[:allowed_workflow_ids] = permitted[:allowed_workflow_ids].compact_blank.map(&:to_i)
    end
    permitted
  end

  def share_emails
    params.dig(:backend, :share_emails).to_s.split(/[\s,]+/).compact_blank.map(&:downcase).uniq
  end

  # Returns the emails that matched no user.
  def sync_shares!
    return [] unless params[:backend]&.key?(:share_emails)

    wanted = User.where(email: share_emails).where.not(id: @backend.owner_user_id).to_a
    current = @backend.shared_users.to_a
    (wanted - current).each { share_with!(it) }
    (current - wanted).each { unshare_with!(it) }
    share_emails - wanted.map(&:email) - [@backend.owner_user&.email]
  end

  def share_with!(user)
    @backend.backend_shares.create!(user:)
    audit(:server_shared, "Shared #{@backend.name} with #{user.display_name}", user_id: user.id)
  end

  def unshare_with!(user)
    @backend.backend_shares.where(user:).delete_all
    audit(:server_unshared, "Stopped sharing #{@backend.name} with #{user.display_name}", user_id: user.id)
  end

  def unknown_emails_alert(emails)
    "No user with email #{emails.to_sentence}." if emails.any?
  end

  def audit_policy_changes(before)
    changed = @backend.attributes.slice(*policy_attributes).reject { |key, value| before[key] == value }
    return if changed.empty?

    audit(:server_updated, "Changed #{changed.keys.map(&:humanize).to_sentence.downcase} on #{@backend.name}",
          changes: changed.to_h { |key, value| [key, [before[key], value]] })
  end

  def audit(kind, message, **details)
    ActivityLog.record(kind:, message:, user: current_user, subject: @backend, details:, request:)
  end
end

# Who may register, manage, and run jobs on servers. Private servers are for their owner, shared
# servers also for the users on their share list, public servers for everyone.
class BackendPolicy
  def initialize(user)
    @user = user
  end

  def can_register? = @user.present? && (@user.admin? || AppSetting.current.allow_user_backends?)

  def can_manage?(backend) = @user.present? && !backend.deleted? && (@user.admin? || backend.owned_by?(@user))

  def can_use?(backend)
    return false if @user.nil? || backend.deleted? || !backend.enabled?

    backend.legacy? || backend.owned_by?(@user) || visible_to_user?(backend)
  end

  def visible_to_user?(backend)
    backend.visibility == 'public' ||
      (backend.visibility == 'shared' && backend.backend_shares.exists?(user_id: @user.id))
  end

  # Whether the owner's private details (system info, other users' prompts) may be shown.
  def can_see_details?(backend) = can_manage?(backend)

  # Agent servers this user can run jobs on.
  def usable_agent_backends
    return Backend.none if @user.nil?

    shared = BackendShare.where(user_id: @user.id).select(:backend_id)
    Backend.agent.enabled.where(owner_user_id: @user.id)
           .or(Backend.agent.enabled.where(visibility: 'public'))
           .or(Backend.agent.enabled.where(visibility: 'shared', id: shared))
  end

  # Legacy HTTP backends and agent servers this user may run jobs on.
  def runnable_backends
    return Backend.none if @user.nil?

    legacy_ids = Backend.legacy.enabled.select { can_use?(it) }.map(&:id)
    Backend.where(id: usable_agent_backends.select(:id)).or(Backend.where(id: legacy_ids)).ordered
  end

  # Servers listed on /servers: usable ones, plus everything for admins.
  def listable_backends
    return Backend.agent.kept if @user&.admin?

    usable_agent_backends.or(Backend.agent.kept.where(owner_user_id: @user.id))
  end

  def affinity
    return @user.backend_affinity unless @user.backend_affinity == 'auto'

    @user.owned_backends.agent.kept.exists? ? 'prefer_mine' : 'any'
  end
end

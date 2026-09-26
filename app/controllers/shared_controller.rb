# Results members have chosen to share with everyone.
class SharedController < ApplicationController
  PER_PAGE = 24

  def index
    @kind_counts = Generation.shared.group(:kind).count
    scope = Generation.shared.recent.with_attached_outputs.includes(:user, :workflow)
    @kind = params[:kind].presence_in(GenerationKind.keys)
    scope = scope.where(kind: @kind) if @kind
    scope = scope.where(user: current_user) if params[:mine] == '1'
    @pagy, @generations = pagy(:offset, scope, limit: PER_PAGE)
  end

  def show
    @generation = Generation.shared.with_attached_outputs.find(params[:id])
  end

  def unshare
    generation = Generation.shared.find(params[:id])
    return head :not_found unless current_user.admin? || generation.user_id == current_user.id

    generation.unshare!
    notify_owner_moderation(generation, :unshared) if current_user.admin? && generation.user_id != current_user.id
    redirect_to shared_index_path, notice: 'Share removed.', status: :see_other
  end

  def revoke_public_link
    generation = Generation.find(params[:id])
    return head :not_found unless current_user.admin?
    return head :not_found unless generation.publicly_linked?

    generation.revoke_public_link!
    notify_owner_moderation(generation, :link_revoked)
    redirect_to shared_path(generation), notice: 'Public link revoked.', status: :see_other
  end

  def destroy_generation
    generation = Generation.find(params[:id])
    return head :not_found unless current_user.admin?

    title = generation.title
    owner = generation.user
    generation.destroy!
    NotifyOwnerOfModerationJob.perform_later(owner, title:, action: :deleted)
    redirect_to shared_index_path, notice: 'Result deleted.', status: :see_other
  end

  private

  def notify_owner_moderation(generation, action)
    NotifyOwnerOfModerationJob.perform_later(generation.user, title: generation.title, action:)
  end
end

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
    redirect_to shared_index_path, notice: 'Share removed.', status: :see_other
  end
end

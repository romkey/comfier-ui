module Servers
  # Manual model downloads onto a server, and cancelling them.
  class DownloadsController < ApplicationController
    before_action :set_backend
    before_action :require_view, only: :index
    before_action :require_manage, only: %i[create destroy clear cancel_all]

    def index
      @downloads = @backend.model_downloads.agent.recent.limit(20)
      @can_manage = BackendPolicy.new(current_user).can_manage?(@backend)
      render layout: false
    end

    def create
      downloads = Agent::DownloadPlanner.manual!(@backend, selected_models, user: current_user)
      notice = downloads.any? ? "Queued #{downloads.size} download(s) on #{@backend.name}." : 'Nothing to download.'
      redirect_back_or_to server_path(@backend), notice:, status: :see_other
    end

    def destroy
      download = @backend.model_downloads.find(params[:id])
      Agent::DownloadLifecycle.cancel_by_user!(download, user: current_user)
      redirect_back_or_to server_path(@backend), notice: 'Cancelling the download.', status: :see_other
    end

    # Queued ones go first, so cancelling one that's running doesn't start a queued one in its place.
    def cancel_all
      cancellable = @backend.model_downloads.agent.where(agent_state: Agent::DownloadSender::PENDING - %w[cancelling])
      ids = cancellable.order(Arel.sql("CASE WHEN agent_state = 'queued' THEN 0 ELSE 1 END")).pluck(:id)
      count = ids.count { Agent::DownloadLifecycle.cancel_by_user!(ModelDownload.find(it)) }
      if count.positive?
        ActivityLog.record(kind: :model_download_cancelled, user: current_user, subject: @backend,
                           message: "Cancelled #{count} download(s) on #{@backend.name}")
      end
      notice = count.positive? ? "Cancelling #{helpers.pluralize(count, 'download')}." : 'Nothing to cancel.'
      redirect_back_or_to server_path(@backend), notice:, status: :see_other
    end

    def clear
      count = Agent::ModelDeleter.failures(@backend).size
      Agent::ModelDeleter.clear_failures!(@backend)
      scope = @backend.model_downloads.agent.finished
      count += scope.count
      scope.delete_all
      if count.positive?
        Turbo::StreamsChannel.broadcast_refresh_later_to([@backend, :downloads],
                                                         target: "server_downloads_#{@backend.id}")
      end
      notice = count.positive? ? "Cleared #{helpers.pluralize(count, 'entry')} from the log." : 'Nothing to clear.'
      redirect_back_or_to server_path(@backend), notice:, status: :see_other
    end

    private

    def set_backend
      @backend = Backend.agent.kept.find(params[:server_id])
    end

    def require_view
      policy = BackendPolicy.new(current_user)
      head :not_found unless policy.can_manage?(@backend) || policy.can_use?(@backend)
    end

    def require_manage
      head :not_found unless BackendPolicy.new(current_user).can_manage?(@backend)
    end

    # Every workflow's missing models, one workflow's, or one file given by folder, name, and link. Models keep
    # the checksum, size and conversion the server's requirements give them; only a picked file has none.
    def selected_models
      return @backend.downloadable_agent_models if download_all?
      return workflow_models if params[:workflow_id].present?

      requirement = ModelRequirement.new(directory: params[:folder], name: params[:filename], url: params[:url])
      return [] unless requirement.problems.empty? && requirement.url

      [{ 'folder' => requirement.directory, 'filename' => requirement.name, 'url' => requirement.url }]
    end

    def workflow_models = Agent::Availability.downloadable(Workflow.find(params[:workflow_id]), @backend)

    def download_all? = ActiveModel::Type::Boolean.new.cast(params[:all])
  end
end

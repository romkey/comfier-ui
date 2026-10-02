module Servers
  # Manual model downloads onto a server, and cancelling them.
  class DownloadsController < ApplicationController
    before_action :set_backend
    before_action :require_view, only: :index
    before_action :require_manage, only: %i[create destroy]

    def index
      @downloads = @backend.model_downloads.agent.recent.limit(20)
      @can_manage = BackendPolicy.new(current_user).can_manage?(@backend)
      render layout: false
    end

    def create
      requirements = selected_requirements
      downloads = Backends::AgentRunner.new.download(@backend, requirements, user: current_user)
      notice = downloads.any? ? "Queued #{downloads.size} download(s) on #{@backend.name}." : 'Nothing to download.'
      redirect_back_or_to server_path(@backend), notice:, status: :see_other
    end

    def destroy
      download = @backend.model_downloads.find(params[:id])
      Agent::DownloadLifecycle.cancel_by_user!(download, user: current_user)
      redirect_back_or_to server_path(@backend), notice: 'Cancelling the download.', status: :see_other
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

    # Either a workflow's missing models, or one file given by folder, name, and link.
    def selected_requirements
      if params[:workflow_id].present?
        workflow = Workflow.find(params[:workflow_id])
        Agent::Availability.compute(workflow, @backend).models.map do |model|
          ModelRequirement.new(directory: model['folder'], name: model['filename'], url: model['url'])
        end
      else
        requirement = ModelRequirement.new(directory: params[:folder], name: params[:filename], url: params[:url])
        requirement.problems.empty? && requirement.url ? [requirement] : []
      end
    end
  end
end

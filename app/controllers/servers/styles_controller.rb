module Servers
  # Live-updating style availability for one server page.
  class StylesController < ApplicationController
    before_action :set_backend
    before_action :require_view

    def show
      @can_manage = BackendPolicy.new(current_user).can_manage?(@backend)
      @workflows = Workflow.enabled.ordered.to_a
      @availability = @backend.workflow_availabilities.index_by(&:workflow_id)
      render layout: false
    end

    private

    def set_backend
      @backend = Backend.agent.kept.find(params[:server_id])
    end

    def require_view
      policy = BackendPolicy.new(current_user)
      head :not_found unless policy.can_manage?(@backend) || policy.can_use?(@backend)
    end
  end
end

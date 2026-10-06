module Servers
  # Live-updating style availability for one server page.
  class StylesController < ApplicationController
    before_action :set_backend
    before_action :require_view, only: :show
    before_action :require_manage, only: %i[rescan update]

    def show
      load_styles
      render layout: false
    end

    def rescan
      @backend.refresh_inventory!
      @rescan_requested = true
      load_styles
      render :show, layout: false
    end

    # Turns one style on or off for this server.
    def update
      workflow = Workflow.find(params.require(:workflow_id))
      enabled = ActiveModel::Type::Boolean.new.cast(params.require(:enabled))
      audit_toggle(workflow, enabled) if Agent::ServerStyles.set!(@backend, workflow, enabled:)
      load_styles
      render :show, layout: false
    end

    private

    def audit_toggle(workflow, enabled)
      ActivityLog.record(kind: :server_updated, user: current_user, subject: @backend, request:,
                         message: "Turned #{enabled ? 'on' : 'off'} #{workflow.name} on #{@backend.name}",
                         details: { workflow_id: workflow.id, enabled: })
    end

    def set_backend
      @backend = Backend.agent.kept.find(params[:server_id])
    end

    def load_styles
      @can_manage = BackendPolicy.new(current_user).can_manage?(@backend)
      @workflows = Workflow.enabled.ordered.to_a
      @availability = @backend.workflow_availabilities.index_by(&:workflow_id)
    end

    def require_view
      policy = BackendPolicy.new(current_user)
      head :not_found unless policy.can_manage?(@backend) || policy.can_use?(@backend)
    end

    def require_manage
      head :not_found unless BackendPolicy.new(current_user).can_manage?(@backend)
    end
  end
end

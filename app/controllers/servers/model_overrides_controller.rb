module Servers
  # A server's model overrides: its own versions of model files its workflows name (see ModelOverride).
  class ModelOverridesController < ApplicationController
    ROW_FIELDS = %i[id file workflow_id replacement_folder replacement_filename url sha256 note remove].freeze

    before_action :set_backend
    before_action :require_manage

    def show
      load_page
      @rows = @overrides + [new_row]
    end

    def update
      editor = Agent::ModelOverrideEditor.new(@backend, user: current_user, request:)
      if editor.apply!(override_rows)
        redirect_to server_model_overrides_path(@backend, workflow_id: params[:workflow_id].presence),
                    notice: editor.notice, status: :see_other
      else
        load_page
        @errors = editor.errors
        @rows = editor.records
        @rows += [new_row] if @rows.none?(&:new_record?)
        render :show, status: :unprocessable_content
      end
    end

    private

    def set_backend
      @backend = Backend.agent.kept.find(params[:server_id])
    end

    def require_manage
      head :not_found unless BackendPolicy.new(current_user).can_manage?(@backend)
    end

    def load_page
      @workflow = Workflow.find_by(id: params[:workflow_id]) if params[:workflow_id].present?
      @files = Agent::OverrideCandidates.for(@backend, workflow: @workflow)
      @workflows = @backend.workflows_for_server.select(&:comfyui?)
      scope = @backend.model_overrides.includes(:workflow).ordered
      @overrides = (@workflow ? scope.where(workflow_id: [nil, @workflow.id]) : scope).to_a
    end

    # The blank row for a new override, filled in from the file an "Override" link picked.
    def new_row
      folder, filename = params[:file].to_s.split('/', 2)
      @backend.model_overrides.build(folder:, filename:, workflow: @workflow)
    end

    def override_rows
      rows = params[:overrides]
      return [] unless rows.is_a?(ActionController::Parameters)

      rows.each_value.map { it.permit(*ROW_FIELDS).to_h }
    end
  end
end

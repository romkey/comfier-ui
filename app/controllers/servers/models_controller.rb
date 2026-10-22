module Servers
  # Deleting models from a server, and reloading them (delete, then download again): files picked from its
  # inventory, one workflow's models, or every workflow's (all=1).
  class ModelsController < ApplicationController
    before_action :set_backend
    before_action :require_manage
    before_action :require_support

    def destroy
      selection = chosen_models
      count = Agent::ModelDeleter.delete!(@backend, selection.installed, user: current_user)
      redirect_back_or_to server_path(@backend), status: :see_other, notice: delete_notice(selection, count)
    end

    def reload
      selection = chosen_models
      outcome = Agent::ModelDeleter.reload!(@backend, selection, user: current_user)
      redirect_back_or_to server_path(@backend), status: :see_other, notice: reload_notice(selection, outcome)
    end

    private

    def set_backend
      @backend = Backend.agent.kept.find(params[:server_id])
    end

    def require_manage
      head :not_found unless BackendPolicy.new(current_user).can_manage?(@backend)
    end

    def require_support
      reason = Agent::ModelDeleter.blocker(@backend)
      reason ||= "#{@backend.name} is offline." unless Agent::Presence.online?(@backend)
      redirect_back_or_to server_path(@backend), alert: reason, status: :see_other if reason
    end

    def chosen_models
      if ActiveModel::Type::Boolean.new.cast(params[:all])
        Agent::ServerModels.for_server(@backend)
      elsif params[:workflow_id].present?
        Agent::ServerModels.for_workflow(Workflow.find(params[:workflow_id]), @backend)
      else
        Agent::ServerModels.for_files(@backend, Array(params[:files]).compact_blank)
      end
    end

    def delete_notice(selection, count)
      return 'Nothing to delete.' if selection.installed.empty?

      "Deleting #{helpers.pluralize(count, 'model')} on #{@backend.name}."
    end

    def reload_notice(selection, outcome)
      parts = []
      parts << "deleting #{helpers.pluralize(outcome.deleted, 'model')}" if outcome.deleted.positive?
      parts << "queued #{helpers.pluralize(outcome.queued, 'download')}" if outcome.queued.positive?
      text = parts.any? ? "#{parts.join(' and ').upcase_first} on #{@backend.name}." : 'Nothing to reload.'
      missing = no_link_count(selection)
      missing.positive? ? "#{text} #{helpers.pluralize(missing, 'model')} had no download link." : text
    end

    def no_link_count(selection)
      selection.installed.count { Agent::ServerModels.downloads_for(selection.downloads, it).empty? }
    end
  end
end

module Admin
  class WorkflowsController < BaseController # rubocop:disable Metrics/ClassLength
    before_action :set_workflow, only: %i[edit update destroy models check_models install_models requirements
                                          update_requirements prepare_servers]
    before_action :load_model_status, only: :models

    def index
      @workflows = Workflow.ordered.group_by(&:kind)
      @usage_counts = Generation.group(:workflow_id).count
      @backends = Backend.legacy.enabled.ordered.to_a
    end

    def new
      @workflow = Workflow.new(kind: params[:kind].presence_in(GenerationKind.keys) || 'image')
    end

    def edit
      @usage_count = Generation.where(workflow_id: @workflow.id).count
    end

    # The models table, loaded into a frame on the edit page and reloaded as downloads progress.
    def models
      render layout: false
    end

    def create
      @workflow = Workflow.new
      return suggest_placeholders if params[:suggest_placeholders].present?

      assign_workflow
      apply_reviewed_placeholders
      if @workflow.save
        redirect_to edit_admin_workflow_path(@workflow), notice: saved_notice("Added #{@workflow.name}."),
                                                         status: :see_other
      else
        render :new, status: :unprocessable_content
      end
    end

    def update
      return suggest_placeholders if params[:suggest_placeholders].present?

      assign_workflow
      apply_reviewed_placeholders
      if @workflow.save
        redirect_to edit_admin_workflow_path(@workflow), notice: saved_notice("Saved #{@workflow.name}."),
                                                         status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end

    # Proposes placeholders for review without touching the JSON; the checked ones are applied on save.
    def suggest_placeholders
      assign_workflow
      @placeholder_suggestion = PlaceholderSuggester.call(@workflow.graph_json, user: current_user)
      flash.now[:notice] = suggestion_notice(@placeholder_suggestion)
      respond_to_suggest_form
    rescue PlaceholderSuggester::Error => e
      flash.now[:alert] = e.message
      respond_to_suggest_form
    end

    def destroy
      @workflow.destroy!
      redirect_to admin_workflows_path, notice: "Removed #{@workflow.name}.", status: :see_other
    end

    def check_models
      directories = @workflow.required_models.map(&:directory).uniq
      unreachable = Backend.legacy.enabled.ordered.reject { it.refresh_inventory!(directories) }
      notice = unreachable.any? ? "Couldn't reach #{unreachable.map(&:name).to_sentence}." : 'Checked every backend.'
      redirect_to edit_admin_workflow_path(@workflow, anchor: 'models'), notice:, status: :see_other
    end

    def install_models
      backend = Backend.legacy.enabled.find(params[:backend_id])
      outcome = Backends::Runner.for_backend(backend).download(backend, backend.missing_models(@workflow))
      redirect_to edit_admin_workflow_path(@workflow, anchor: 'models'), notice: install_notice(backend, outcome),
                                                                         status: :see_other
    end

    # Agent-server requirements (editable) and which servers can run the workflow.
    def requirements
      @models = @workflow.workflow_models
      @servers = Backend.agent.kept.ordered.to_a
      @availability = @workflow.workflow_availabilities.index_by(&:backend_id)
    end

    def update_requirements
      WorkflowRequirementsEditor.new(@workflow).apply!(requirement_rows, @workflow.agent_requirements)
      redirect_to requirements_admin_workflow_path(@workflow), notice: 'Saved the model list.', status: :see_other
    end

    # Queues every missing model on the chosen servers.
    def prepare_servers
      servers = Backend.agent.kept.where(id: Array(params[:backend_ids])).select { it.allows_workflow?(@workflow) }
      queued = servers.sum do |backend|
        models = Agent::Availability.compute(@workflow, backend).models
        Agent::DownloadPlanner.manual!(backend, models, user: current_user).size
      end
      redirect_to requirements_admin_workflow_path(@workflow),
                  notice: "Queued #{helpers.pluralize(queued,
                                                      'download')} on #{helpers.pluralize(servers.size, 'server')}.",
                  status: :see_other
    end

    private

    def requirement_rows
      rows = params[:models]
      return [] unless rows.is_a?(ActionController::Parameters)

      rows.each_value.map { it.permit(:id, :folder, :filename, :url, :sha256, :remove).to_h }
    end

    def set_workflow
      @workflow = Workflow.find(params[:id])
    end

    def load_model_status
      @backends = Backend.legacy.enabled.ordered.to_a
      @downloads = ModelDownload.where(backend: @backends).recent
                                .group_by { [it.backend_id, it.directory, it.name] }.transform_values(&:first)
    end

    # The models file is applied after the text list so its download links fill in what's typed.
    def assign_workflow
      permitted = params.expect(workflow: %i[name kind description graph_json graph_file enabled position
                                             base_resolution frame_rate steps guidance timeout_minutes
                                             required_models_text models_file])
      exports = WorkflowExportRouter.route(
        @workflow,
        graph_file: permitted.delete(:graph_file),
        models_file: permitted.delete(:models_file)
      )
      @export_swap_notice = exports.swap_notice
      permitted[:graph_json] = exports.graph_content if exports.graph_content.present?
      @workflow.assign_attributes(permitted)
      @workflow.import_models(exports.models_content) if exports.models_content.present?
    end

    # The rows ticked in the placeholder review. The graph's own validation reports a malformed workflow.
    def apply_reviewed_placeholders
      substitutions = reviewed_substitutions
      return if substitutions.empty?

      applied = PlaceholderSuggester.apply(@workflow.graph, substitutions)
      @workflow.graph_json = JSON.pretty_generate(applied.graph)
      @placeholder_notice = applied_notice(applied)
    rescue PlaceholderSuggester::Error
      nil
    end

    def reviewed_substitutions
      rows = params[:placeholder_substitutions]
      return [] unless rows.is_a?(ActionController::Parameters)

      rows.each_value.filter_map do |row|
        next unless row.is_a?(ActionController::Parameters)

        row = row.permit(:node, :input, :placeholder, :source, :apply)
        next unless row[:apply] == '1'

        PlaceholderSuggester::Substitution.new(
          node: row[:node].to_s, input: row[:input].to_s, placeholder: row[:placeholder].to_s, old_value: nil,
          source: row[:source].presence_in(%w[rule llm manual]) || 'manual'
        )
      end
    end

    def applied_notice(applied)
      count = applied.substitutions.size
      parts = ["Applied #{count} #{'placeholder'.pluralize(count)}."]
      parts << "Skipped #{applied.errors.size}: #{applied.errors.to_sentence}." if applied.errors.any?
      parts.join(' ')
    end

    def saved_notice(message)
      [message, @placeholder_notice, @export_swap_notice].compact.join(' ')
    end

    def suggestion_notice(result)
      count = result.substitutions.size
      parts = if count.zero?
                ['No placeholders found. Add any by hand below.']
              else
                ["Proposed #{count} #{'placeholder'.pluralize(count)}. Untick any you don't want, then choose Save."]
              end
      parts << @export_swap_notice if @export_swap_notice.present?
      parts.join(' ')
    end

    def respond_to_suggest_form
      @usage_count = Generation.where(workflow_id: @workflow.id).count if @workflow.persisted?
      status = flash.now[:alert].present? ? :unprocessable_content : :ok

      respond_to do |format|
        format.turbo_stream { render :suggest_placeholders, status: }
        format.html { render(@workflow.persisted? ? :edit : :new, status:) }
      end
    end

    def install_notice(backend, outcome)
      parts = [
        count_phrase(outcome.queued, 'download', "started on #{backend.name}"),
        count_phrase(outcome.already_running, 'download', 'already running'),
        count_phrase(outcome.unavailable, 'file', "can't be downloaded there")
      ].compact
      return "#{backend.name} already has every model." if parts.empty?

      "#{parts.join('; ')}. Progress and any problems show under Models."
    end

    def count_phrase(items, noun, rest)
      "#{helpers.pluralize(items.size, noun)} #{rest}" if items.any?
    end
  end
end

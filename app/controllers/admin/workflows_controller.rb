module Admin
  class WorkflowsController < BaseController
    before_action :set_workflow, only: %i[edit update destroy models check_models install_models]
    before_action :load_model_status, only: :models

    def index
      @workflows = Workflow.ordered.group_by(&:kind)
      @usage_counts = Generation.group(:workflow_id).count
      @backends = Backend.enabled.ordered.to_a
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
      assign_workflow
      if @workflow.save
        redirect_to edit_admin_workflow_path(@workflow), notice: "Added #{@workflow.name}.", status: :see_other
      else
        render :new, status: :unprocessable_content
      end
    end

    def update
      assign_workflow
      if @workflow.save
        redirect_to edit_admin_workflow_path(@workflow), notice: "Saved #{@workflow.name}.", status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @workflow.destroy!
      redirect_to admin_workflows_path, notice: "Removed #{@workflow.name}.", status: :see_other
    end

    def check_models
      directories = @workflow.required_models.map(&:directory).uniq
      unreachable = Backend.enabled.ordered.reject { it.refresh_inventory!(directories) }
      notice = unreachable.any? ? "Couldn't reach #{unreachable.map(&:name).to_sentence}." : 'Checked every backend.'
      redirect_to edit_admin_workflow_path(@workflow, anchor: 'models'), notice:, status: :see_other
    end

    def install_models
      backend = Backend.enabled.find(params[:backend_id])
      outcome = ModelInstaller.queue(backend, backend.missing_models(@workflow))
      redirect_to edit_admin_workflow_path(@workflow, anchor: 'models'), notice: install_notice(backend, outcome),
                                                                         status: :see_other
    end

    private

    def set_workflow
      @workflow = Workflow.find(params[:id])
    end

    def load_model_status
      @backends = Backend.enabled.ordered.to_a
      @downloads = ModelDownload.where(backend: @backends).recent
                                .group_by { [it.backend_id, it.directory, it.name] }.transform_values(&:first)
    end

    # The models file is applied after the text list so its download links fill in what's typed.
    def assign_workflow
      permitted = params.expect(workflow: %i[name kind description graph_json graph_file enabled position
                                             base_resolution frame_rate steps guidance required_models_text
                                             models_file])
      graph_file = permitted.delete(:graph_file)
      models_file = permitted.delete(:models_file)
      permitted[:graph_json] = graph_file.read if graph_file.respond_to?(:read)
      @workflow.assign_attributes(permitted)
      @workflow.import_models(models_file.read) if models_file.respond_to?(:read)
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

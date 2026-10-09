# frozen_string_literal: true

module Agent
  # Availability for mflux and MLX video workflows: the server has to run the engine and have the
  # memory the recipe asks for. A model that isn't on the server yet doesn't block the style (the engine
  # downloads it on the first run), so it stays ready, with a hint and the model offered as a download
  # (`models`) that can be fetched ahead from the server's page.
  class EngineAvailability
    def initialize(workflow, backend)
      @workflow = workflow
      @backend = backend
      @engine = workflow.engine
    end

    def compute
      reason = blocking_reason
      return result(:blocked, reasons: [reason]) if reason

      missing = missing_models
      return result(:ready) if missing.empty?

      downloads = @backend.can_download_models? ? missing.map { download(it) } : []
      result(:ready, models: downloads, hints: [model_hint(missing)])
    end

    # A model as a download: directory is the engine, name the model (or repo) it fetches.
    def download(model) = { 'folder' => @engine, 'filename' => model, 'engine' => @engine }

    private

    def blocking_reason
      return "#{@backend.name} runs ComfyUI only" if @backend.legacy?
      return "#{@backend.name} hasn't reported its engines yet" unless @backend.backend_inventory
      return "#{@backend.name} doesn't run #{@workflow.engine_info.label}" unless @backend.runs_engine?(@engine)

      memory_reason
    end

    def memory_reason
      needed = @workflow.min_memory_gb
      total = @backend.ram_total
      return unless needed && total && total < needed.gigabytes * 0.95

      "#{@backend.name} has #{ActiveSupport::NumberHelper.number_to_human_size(total)} of memory; " \
        "#{@workflow.name} needs about #{needed} GB"
    end

    def result(status, models: [], reasons: [], hints: [])
      Availability::Result.new(status:, models:, total_bytes: nil, reasons:, hints:)
    end

    # Not reported by the engine and not just downloaded (the engine's next inventory will list those).
    def missing_models
      reported = @backend.engine_models(@engine)
      just_downloaded = @backend.backend_models.where(folder: @engine).pluck(:filename)
      @workflow.recipe_models - reported - just_downloaded
    end

    def model_hint(missing)
      "#{missing.to_sentence} #{missing.one? ? "isn't" : "aren't"} downloaded on #{@backend.name} yet; " \
        'the first run downloads it, so it takes longer'
    end
  end
end

# frozen_string_literal: true

module Agent
  # Availability for mflux and MLX video workflows: the server has to run the engine and have the
  # memory the recipe asks for. A model that isn't on the server yet doesn't block the style; the
  # engine downloads it on the first run, so that's a hint rather than a reason.
  class EngineAvailability
    def initialize(workflow, backend)
      @workflow = workflow
      @backend = backend
      @engine = workflow.engine
    end

    def compute
      reason = blocking_reason
      status = reason ? :blocked : :ready
      Availability::Result.new(status:, models: [], total_bytes: nil, reasons: [reason].compact,
                               hints: reason ? [] : model_hints)
    end

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

    def model_hints
      model = @workflow.recipe_model
      return [] if model.blank? || @backend.engine_models(@engine).include?(model)

      ["#{model} isn't downloaded on #{@backend.name} yet; the first run downloads it, so it takes longer"]
    end
  end
end

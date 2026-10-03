# frozen_string_literal: true

module Agent
  # Whether a workflow can run on a server: ready, needs_downloads (every missing model has a link
  # and fits on disk), or blocked (with reasons). Results are cached in workflow_availabilities.
  class Availability
    Result = Data.define(:status, :models, :total_bytes, :reasons, :hints) do
      def ready? = status == :ready
      def needs_downloads? = status == :needs_downloads
      def blocked? = status == :blocked
      def missing_node_types = reasons.grep(/\ANode type /)
    end

    class << self
      def compute(workflow, backend) = new(workflow, backend).compute

      def store!(workflow, backend)
        result = new(workflow, backend).compute
        record = WorkflowAvailability.find_or_initialize_by(workflow_id: workflow.id, backend_id: backend.id)
        record.update!(status: result.status.to_s, details: details(result, Requirements.for(workflow).models.size))
        result
      end

      def recompute_for_backend!(backend)
        Workflow.enabled.find_each { store!(it, backend) }
      end

      def recompute_for_workflow!(workflow)
        Backend.agent.kept.find_each { store!(workflow, it) }
      end

      def details(result, required_model_count = nil)
        { 'reasons' => result.reasons, 'hints' => result.hints, 'total_bytes' => result.total_bytes,
          'models' => result.models.map { it.slice('folder', 'filename', 'bytes') },
          'required_model_count' => required_model_count }
      end
    end

    def initialize(workflow, backend)
      @workflow = workflow
      @backend = backend
      @requirements = Requirements.for(workflow)
    end

    def compute
      @backend.ensure_routing_inventory! if @backend.legacy?
      return blocked(["#{@backend.name} hasn't reported its models yet"]) unless @backend.backend_inventory

      missing = missing_models
      hints = hints_for(missing)
      reasons = missing_node_reasons + strict_reasons(missing) + model_reasons(missing)
      return blocked(reasons, hints) if reasons.any?
      return Result.new(status: :ready, models: [], total_bytes: nil, reasons: [], hints:) if missing.empty?

      downloads(missing, hints)
    end

    private

    def downloads(missing, hints)
      total = missing.sum { it['bytes'].to_i }
      disk = disk_reason(total)
      return blocked([disk], hints, missing) if disk

      Result.new(status: :needs_downloads, models: missing, total_bytes: total.positive? ? total : nil,
                 reasons: [], hints:)
    end

    def blocked(reasons, hints = [], models = [])
      Result.new(status: :blocked, models:, total_bytes: nil, reasons:, hints:)
    end

    def missing_models
      matcher = ModelMatcher.new(@backend.backend_models.pluck(:folder, :filename))
      @requirements.models.reject { matcher.present?(it['folder'], it['filename']) }
    end

    def hints_for(missing)
      return [] if @backend.legacy?

      matcher = ModelMatcher.new(@backend.backend_models.pluck(:folder, :filename))
      missing.filter_map { hint(matcher, it) }
    end

    def missing_node_reasons
      have = Array(@backend.backend_inventory.node_types_json)
      return [] if @backend.legacy? && have.empty?

      (@requirements.node_types - have).map { "Node type #{it} isn't installed" }
    end

    def model_reasons(missing)
      missing.filter_map do |model|
        if model['url'].blank?
          "#{model['folder']}/#{model['filename']} is missing and has no download link"
        elsif !@backend.can_download_models?
          "#{model['folder']}/#{model['filename']} is missing and #{@backend.name} doesn't allow model downloads"
        end
      end
    end

    def hint(matcher, model)
      found = matcher.elsewhere(model['folder'], model['filename'])
      "#{model['filename']} is at #{found}; the workflow expects #{model['folder']}/#{model['filename']}" if found
    end

    def disk_reason(total)
      free = Presence.disk_free(@backend)
      return unless free && total.positive?
      return unless free - total < AgentTiming::MIN_FREE_DISK_GB.gigabytes

      "Not enough disk space on #{@backend.name} for #{ActiveSupport::NumberHelper.number_to_human_size(total)} " \
        'of models'
    end

    # With object_info cached, literal values for list-typed inputs must be one of the options.
    # Models already counted as missing (and being downloaded) are skipped.
    def strict_reasons(missing)
      return [] if @backend.legacy?

      strict_combo_reasons(missing, @backend.backend_object_infos.first&.data)
    end

    def strict_combo_reasons(missing, info)
      return [] if info.blank?

      skip = missing.to_set { it['filename'] }
      Requirements.literal_inputs(@workflow.graph).filter_map do |id, node, input, value|
        next if skip.include?(value)

        options = ObjectInfoStore.options_for(info, node['class_type'], input)
        next if options.nil? || options.include?(value)

        "Node #{id} (#{node['class_type']}): #{input} “#{value}” isn't available on #{@backend.name}"
      end
    end
  end
end

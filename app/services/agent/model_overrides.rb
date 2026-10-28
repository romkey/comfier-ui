# frozen_string_literal: true

module Agent
  # A server's model overrides (ModelOverride) applied to one workflow: the models it needs there and the graph its
  # jobs send. ModelSubstitution applies these first, then Apple Silicon's fp16 stand-ins (MacWeights).
  class ModelOverrides
    GGUF = /\.gguf\z/i

    REPLANNED = %w[queued waiting_models].freeze

    # After an override changes, jobs queued or waiting for downloads on the server get the files they need now,
    # before one is sent with a file the server doesn't have: they queue when those are all there, wait for their
    # downloads, or try another server when the workflow can't run there at all any more.
    # workflow_ids: only those workflows' jobs; nil for every workflow's.
    def self.replan_jobs!(backend, workflow_ids: nil)
      jobs = backend.generations.where(agent_state: REPLANNED)
      jobs = jobs.where(workflow_id: workflow_ids) if workflow_ids
      jobs.includes(:workflow).find_each { replan!(backend, it) }
      Dispatcher.dispatch_for!(backend)
      Timeline.schedule(backend)
    end

    def self.replan!(backend, generation)
      return unless generation.workflow&.comfyui?

      state = generation.agent_state
      DownloadPlanner.release_generation!(generation) if state == 'waiting_models'
      availability = Availability.compute(generation.workflow, backend)
      if availability.ready?
        generation.agent_transition!(from: 'waiting_models', to: 'queued', queued_at: Time.current)
      elsif availability.needs_downloads?
        wait_for_downloads!(backend, generation, availability.models)
      else
        JobLifecycle.reroute!(generation, exclude: backend, from: state)
      end
    end

    def self.wait_for_downloads!(backend, generation, models)
      return unless generation.agent_state == 'waiting_models' ||
                    generation.agent_transition!(from: 'queued', to: 'waiting_models')

      DownloadPlanner.ensure_downloads!(backend, models, generation:, auto: true)
    end

    def initialize(backend, workflow)
      @backend = backend
      @workflow = workflow
    end

    def active? = overrides.any?

    # The models a workflow needs on this server, with overridden files swapped for their replacements.
    def models(models) = active? ? models.map { substitute(it) || it } : models

    def substitute(model) = override_for(model)&.stand_in(model)

    # The override for one of the workflow's models: the workflow's own wins over one for the whole server.
    def override_for(model)
      matching = overrides.select { it.applies_to?(model) }
      matching.find(&:workflow_id) || matching.first
    end

    # The graph with each overridden file's name swapped for its replacement's.
    def rewrite(graph, models)
      renames = renames(models)
      return graph if renames.empty? || !graph.is_a?(Hash)

      graph.transform_values { rename_inputs(it, renames) }
    end

    # Replacements the node that loads the file can't read: a GGUF file needs a GGUF loader (ComfyUI-GGUF), and a
    # GGUF loader reads nothing else.
    def problems(models, graph)
      renames = renames(models)
      return [] if renames.empty?

      Requirements.literal_inputs(graph).filter_map do |id, node, _input, value|
        replacement = renames[value.tr('\\', '/')]
        next if replacement.nil? || gguf?(replacement) == gguf?(value) || gguf?(replacement) == gguf_loader?(node)

        loader_problem(id, node, value, replacement)
      end.uniq
    end

    private

    def overrides
      @overrides ||= @backend.agent? && @backend.persisted? ? scope.to_a : []
    end

    def scope = @backend.model_overrides.where(workflow_id: [nil, @workflow&.id])

    def renames(models)
      return {} unless active?

      models.each_with_object({}) do |model, map|
        swapped = substitute(model)
        map[model['filename']] = swapped['filename'] if swapped
      end
    end

    def rename_inputs(node, renames)
      return node unless node.is_a?(Hash) && node['inputs'].is_a?(Hash)

      inputs = node['inputs'].transform_values { it.is_a?(String) ? renames.fetch(it.tr('\\', '/'), it) : it }
      node.merge('inputs' => inputs)
    end

    def gguf?(filename) = filename.to_s.match?(GGUF)
    def gguf_loader?(node) = node['class_type'].to_s.match?(/gguf/i)

    def loader_problem(id, node, original, replacement)
      where = "node #{id} (#{node['class_type']})"
      if gguf?(replacement)
        "#{@backend.name} uses #{replacement} in place of #{original}, but #{where} can't load GGUF files; " \
          'the workflow needs a GGUF loader node there'
      else
        "#{@backend.name} uses #{replacement} in place of #{original}, but #{where} only loads GGUF files"
      end
    end
  end
end

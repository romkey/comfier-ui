# frozen_string_literal: true

module Agent
  # What a workflow needs from a server: node types and model files. Models are extracted from the
  # API graph (which names files), joined to the UI export (which has links and hashes), then
  # merged under admin edits and stored as WorkflowModel rows.
  class Requirements # rubocop:disable Metrics/ClassLength
    Req = Data.define(:node_types, :models)

    class << self
      def for(workflow)
        extract!(workflow) if workflow.structure_hash.blank?
        rows = workflow.workflow_models.to_a
        Req.new(node_types: node_types_for(workflow), models: rows.map(&:to_requirement_h))
      end

      # Prefer the live API graph over cached requirements_json (stale after graph edits).
      def node_types_for(workflow)
        return [] unless workflow.comfyui?

        graph = workflow.graph || {}
        from_graph = graph.values.filter_map { |node| node['class_type'].to_s.strip if node.is_a?(Hash) }.uniq.sort
        from_graph.presence || Array(workflow.requirements_json&.dig('node_types'))
      end

      def extract!(workflow) = new(workflow).extract!

      # sha256 of the API graph with keys sorted at every level; placeholders stay placeholders.
      def structure_hash(api_graph) = Digest::SHA256.hexdigest(JSON.generate(canonical(api_graph)))

      def model_set_hash(models)
        Digest::SHA256.hexdigest(models.map { "#{it['folder']}/#{it['filename']}" }.sort.join("\n"))
      end

      # [node_id, node, input_name, value] for every literal string input (placeholders excluded).
      def literal_inputs(graph)
        (graph || {}).flat_map do |id, node|
          inputs = node.is_a?(Hash) ? node['inputs'] : nil
          next [] unless inputs.is_a?(Hash)

          inputs.filter_map { |input, value| [id, node, input, value] if literal?(value) }
        end
      end

      def literal?(value) = value.is_a?(String) && !value.match?(Workflow::PLACEHOLDER)

      def canonical(value)
        case value
        when Hash then value.keys.map(&:to_s).sort.index_with { canonical(value[it] || value[it.to_sym]) }
        when Array then value.map { canonical(it) }
        else value
        end
      end
    end

    def initialize(workflow)
      @workflow = workflow
    end

    def extract!
      api = @workflow.graph || {}
      ui = ui_models
      extracted = api_models(api).map { join_ui(it, ui) }
      extracted += unmatched_ui(ui, extracted)
      extracted += admin_list
      save!(dedupe(extracted), node_types(api), api)
    end

    private

    def node_types(api)
      api.values.filter_map { it['class_type'] if it.is_a?(Hash) }.uniq.sort
    end

    # Every string input with a model extension. Known input names give the folder; anything
    # else is "unknown" until the UI metadata or an admin fills it in.
    def api_models(api)
      self.class.literal_inputs(api).filter_map do |_id, node, input, value|
        next unless WorkflowModels::EXTENSIONS.include?(File.extname(value).downcase)

        folder = WorkflowModels::NODE_INPUT_DIRECTORIES[[node['class_type'], input]] ||
                 WorkflowModels::INPUT_DIRECTORIES[input] || 'unknown'
        { 'folder' => folder, 'filename' => value.tr('\\', '/'), 'source' => 'api' }
      end
    end

    # UI exports list models per node (`properties.models`) and sometimes at the top level.
    def ui_models
      data = @workflow.ui_graph
      return [] unless WorkflowModels.ui_format?(data)

      subgraph_nodes = Array(data.dig('definitions', 'subgraphs')).flat_map { Array(it['nodes']) }
      entries = (data['nodes'] + subgraph_nodes).flat_map { Array(it.dig('properties', 'models')) }
      entries += Array(data['models'])
      entries.filter_map { ui_entry(it) }
    end

    def ui_entry(model)
      return unless model.is_a?(Hash) && model['name'].present?

      sha = model['hash'] if model['hash_type'].to_s.downcase == 'sha256'
      { 'folder' => model['directory'].presence || 'unknown', 'filename' => model['name'].tr('\\', '/'),
        'url' => ModelRequirement.new(directory: 'x', name: 'x', url: model['url']).url,
        'sha256' => sha, 'source' => 'ui' }
    end

    # Exact filename first, then basename (UI exports often drop subdirectories).
    def join_ui(entry, ui)
      match = ui.find { it['filename'] == entry['filename'] } ||
              ui.find { File.basename(it['filename']) == File.basename(entry['filename']) }
      return entry unless match

      folder = entry['folder'] == 'unknown' ? match['folder'] : entry['folder']
      entry.merge('folder' => folder, 'url' => match['url'], 'sha256' => match['sha256']).compact
    end

    def unmatched_ui(ui, extracted)
      names = extracted.map { File.basename(it['filename']) }
      ui.reject { names.include?(File.basename(it['filename'])) }
    end

    def admin_list
      Array(@workflow.extra_models).map do |model|
        { 'folder' => model['directory'], 'filename' => model['name'], 'url' => model['url'], 'source' => 'admin' }
      end
    end

    def dedupe(entries)
      entries.each_with_object({}) do |entry, merged|
        key = [entry['folder'], entry['filename']]
        merged[key] = merged[key] ? merged[key].merge(entry.compact) { |_k, old, new| old.presence || new } : entry
      end.values
    end

    def save!(entries, node_types, api)
      WorkflowModel.transaction do
        admin = @workflow.workflow_models.where(source: 'admin').index_by { [it.folder, it.filename] }
        previous = @workflow.workflow_models.where.not(source: 'admin').index_by { [it.folder, it.filename] }
        @workflow.workflow_models.where.not(source: 'admin').delete_all
        entries.each { write_row(it, admin, previous) }
        update_workflow!(node_types, api)
      end
      @workflow.workflow_models.reload
    end

    def write_row(entry, admin, previous)
      key = [entry['folder'], entry['filename']]
      return if admin.key?(key) || admin_placed?(entry, admin)

      enriched = enriched_row(previous[key], entry)
      @workflow.workflow_models.create!(
        folder: entry['folder'], filename: entry['filename'], url: entry['url'],
        sha256: entry['sha256'] || enriched&.sha256, bytes: enriched&.bytes,
        source: enriched ? 'enriched' : entry['source']
      )
    end

    # Sizes and hashes fetched for a link stay valid while the link does.
    def enriched_row(old, entry) = (old if old&.source == 'enriched' && old.url == entry['url'])

    # An admin who gave an unknown-folder file its folder has answered for that file.
    def admin_placed?(entry, admin)
      entry['folder'] == 'unknown' && admin.values.any? { it.basename == File.basename(entry['filename']) }
    end

    def update_workflow!(node_types, api)
      rows = @workflow.workflow_models.reload
      review = rows.any? { it.unknown_folder? || it.url.blank? }
      @workflow.update_columns( # rubocop:disable Rails/SkipsModelValidations
        requirements_json: { 'node_types' => node_types, 'models' => rows.map(&:to_requirement_h) },
        structure_hash: self.class.structure_hash(api), requirements_need_review: review
      )
    end
  end
end

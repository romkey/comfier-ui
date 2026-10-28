# frozen_string_literal: true

module Agent
  # The model files a server's workflows name, for its overrides page: which workflows use each, whether the server
  # has it, and the overrides that replace it there.
  module OverrideCandidates
    Entry = Data.define(:folder, :filename, :workflows, :installed, :overrides) do
      def key = "#{folder}/#{filename}"
      def server_wide_override = overrides.find(&:server_wide?)
    end

    module_function

    # workflow: only that workflow's files.
    def for(backend, workflow: nil)
      workflows = workflow ? [workflow] : backend.workflows_for_server.select(&:comfyui?)
      overrides = backend.model_overrides.includes(:workflow).to_a
      matcher = ModelMatcher.new(backend.backend_models.pluck(:folder, :filename))
      users_by_file(workflows).sort.map do |(folder, filename), users|
        entry(folder, filename, users, matcher, overrides)
      end
    end

    def users_by_file(workflows)
      workflows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |workflow, files|
        Requirements.for(workflow).models.each { files[[it['folder'], it['filename']]] << workflow }
      end
    end

    def entry(folder, filename, users, matcher, overrides)
      model = { 'folder' => folder, 'filename' => filename }
      ids = users.to_set(&:id)
      applicable = overrides.select { it.applies_to?(model) && (it.server_wide? || ids.include?(it.workflow_id)) }
      Entry.new(folder:, filename:, workflows: users.uniq, installed: matcher.present?(folder, filename),
                overrides: applicable)
    end
  end
end

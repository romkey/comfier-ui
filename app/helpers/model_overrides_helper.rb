module ModelOverridesHelper
  # How many of each workflow's model files a server replaces with its own version (ModelOverride), by workflow id.
  def overridden_file_counts(backend, workflows)
    overrides = backend.model_overrides.to_a
    return {} if overrides.empty?

    models = WorkflowModel.where(workflow_id: workflows.map(&:id)).group_by(&:workflow_id)
    workflows.to_h do |workflow|
      applicable = overrides.select { it.server_wide? || it.workflow_id == workflow.id }
      [workflow.id, Array(models[workflow.id]).count { |m| applicable.any? { it.applies_to?(m.to_requirement_h) } }]
    end
  end
end

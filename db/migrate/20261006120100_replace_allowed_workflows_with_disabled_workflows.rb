# Servers listed the styles they run (empty meant all), so new styles were silently left off any
# server with a list. They now list the styles turned off instead; existing lists are inverted.
class ReplaceAllowedWorkflowsWithDisabledWorkflows < ActiveRecord::Migration[8.1]
  def up
    add_column :backends, :disabled_workflow_ids, :jsonb, default: [], null: false
    execute <<~SQL.squish
      UPDATE backends SET disabled_workflow_ids = COALESCE((
        SELECT jsonb_agg(workflows.id ORDER BY workflows.id) FROM workflows
        WHERE workflows.id::text NOT IN (SELECT jsonb_array_elements_text(backends.allowed_workflow_ids))
      ), '[]'::jsonb)
      WHERE jsonb_typeof(allowed_workflow_ids) = 'array' AND jsonb_array_length(allowed_workflow_ids) > 0
    SQL
    remove_column :backends, :allowed_workflow_ids
  end

  def down
    add_column :backends, :allowed_workflow_ids, :jsonb
    execute <<~SQL.squish
      UPDATE backends SET allowed_workflow_ids = COALESCE((
        SELECT jsonb_agg(workflows.id ORDER BY workflows.id) FROM workflows
        WHERE workflows.id::text NOT IN (SELECT jsonb_array_elements_text(backends.disabled_workflow_ids))
      ), '[]'::jsonb)
      WHERE jsonb_array_length(disabled_workflow_ids) > 0
    SQL
    remove_column :backends, :disabled_workflow_ids
  end
end

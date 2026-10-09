# Performance samples and stats are keyed by the workflow's structure, not its row; workflow_id only says
# which workflow they came from. Deleting a workflow failed on these foreign keys; now it clears them.
class NullifyPerfWorkflowOnDelete < ActiveRecord::Migration[8.1]
  def change
    %i[perf_samples perf_stats].each do |table|
      remove_foreign_key table, :workflows
      add_foreign_key table, :workflows, on_delete: :nullify
    end
  end
end

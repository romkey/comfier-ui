class AddCleanupAfterRunToBackends < ActiveRecord::Migration[8.1]
  def change
    add_column :backends, :cleanup_after_run, :boolean, default: false, null: false
  end
end

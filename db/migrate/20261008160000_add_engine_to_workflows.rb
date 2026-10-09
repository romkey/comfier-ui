class AddEngineToWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :workflows, :engine, :string, null: false, default: 'comfyui'
    add_index :workflows, :engine
  end
end

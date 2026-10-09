class AddEnginesJsonToBackendInventories < ActiveRecord::Migration[8.1]
  def change
    add_column :backend_inventories, :engines_json, :jsonb, null: false, default: {}
  end
end

class AddManagerCatalogToBackends < ActiveRecord::Migration[8.1]
  def change
    add_column :backends, :manager_catalog, :jsonb, null: false, default: {}
  end
end

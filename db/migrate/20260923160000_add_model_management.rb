class AddModelManagement < ActiveRecord::Migration[8.1]
  def change
    # Models admins listed or imported (with download links); loader inputs in the graph are added on top.
    add_column :workflows, :extra_models, :jsonb, null: false, default: []

    change_table :backends, bulk: true do |t|
      t.jsonb :model_inventory, null: false, default: {}
      t.datetime :inventory_checked_at
      t.boolean :downloader_available, null: false, default: false
      t.string :manager_version
    end

    create_table :model_downloads do |t|
      t.references :backend, null: false, foreign_key: { on_delete: :cascade }
      t.string :directory, null: false
      t.string :name, null: false
      t.text :url, null: false
      t.string :status, null: false, default: 'queued'
      t.string :via
      t.string :comfy_prompt_id
      t.text :error_message
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :model_downloads, %i[backend_id directory name], unique: true,
                                                               where: "status IN ('queued', 'running')",
                                                               name: 'index_model_downloads_one_active_per_file'
  end
end

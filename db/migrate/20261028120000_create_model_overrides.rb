# A server's own version of a model file a workflow names, used in its place there (see ModelOverride).
class CreateModelOverrides < ActiveRecord::Migration[8.1]
  def change
    create_table :model_overrides do |t|
      t.references :backend, null: false, foreign_key: true, index: false
      t.references :workflow, foreign_key: true
      t.string :folder, null: false
      t.string :filename, null: false
      t.string :replacement_folder
      t.string :replacement_filename, null: false
      t.text :url
      t.string :sha256
      t.bigint :bytes
      t.string :note
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :model_overrides, %i[backend_id workflow_id folder filename], unique: true, nulls_not_distinct: true,
                                                                            name: 'index_model_overrides_uniqueness'
  end
end

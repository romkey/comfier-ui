class CreateWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :workflows do |t|
      t.string :name, null: false
      t.string :kind, null: false
      t.text :description
      t.jsonb :graph, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.integer :position, null: false, default: 0
      t.integer :base_resolution, null: false, default: 1024
      t.integer :frame_rate, null: false, default: 16

      t.timestamps
    end
    add_index :workflows, %i[kind enabled position]
    add_index :workflows, %i[kind name], unique: true
  end
end

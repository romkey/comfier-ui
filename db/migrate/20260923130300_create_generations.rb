class CreateGenerations < ActiveRecord::Migration[8.1]
  def change
    create_table :generations do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :workflow, foreign_key: { on_delete: :nullify }
      t.references :backend, foreign_key: { on_delete: :nullify }
      t.string :kind, null: false
      t.string :status, null: false, default: 'queued'
      t.text :prompt
      t.text :negative_prompt
      t.jsonb :parameters, null: false, default: {}
      t.string :comfy_prompt_id
      t.text :error_message
      t.datetime :submitted_at
      t.datetime :completed_at

      t.timestamps
    end
    add_index :generations, %i[user_id kind created_at]
    add_index :generations, %i[user_id status]
    add_index :generations, :comfy_prompt_id
  end
end

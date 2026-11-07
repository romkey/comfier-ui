class CreateApiGenerationRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :api_generation_requests do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :generation, foreign_key: { on_delete: :nullify }
      t.string :key_digest, null: false
      t.string :request_digest, null: false
      t.timestamps
    end
    add_index :api_generation_requests, %i[user_id key_digest], unique: true
  end
end

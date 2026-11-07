class CreatePersonalApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :personal_api_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false, limit: 100
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :personal_api_tokens, :token_digest, unique: true
  end
end

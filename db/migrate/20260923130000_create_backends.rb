class CreateBackends < ActiveRecord::Migration[8.1]
  def change
    create_table :backends do |t|
      t.string :name, null: false
      t.string :base_url, null: false
      t.text :auth_token
      t.boolean :enabled, null: false, default: true
      t.datetime :last_checked_at
      t.boolean :last_check_ok # rubocop:disable Rails/ThreeStateBooleanColumn -- nil means never checked
      t.string :last_check_message

      t.timestamps
    end
    add_index :backends, :name, unique: true
    add_index :backends, :enabled
  end
end

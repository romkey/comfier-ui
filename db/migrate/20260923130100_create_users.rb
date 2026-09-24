class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    enable_extension 'citext'

    create_table :users do |t|
      t.string :provider, null: false
      t.string :uid, null: false
      t.citext :email
      t.string :name
      t.string :username
      t.boolean :admin, null: false, default: false
      t.datetime :last_signed_in_at

      t.references :preferred_backend, foreign_key: { to_table: :backends, on_delete: :nullify }
      t.string :default_aspect_ratio, null: false, default: '1:1'
      t.text :default_negative_prompt

      t.timestamps
    end
    add_index :users, %i[provider uid], unique: true
    add_index :users, :email
  end
end

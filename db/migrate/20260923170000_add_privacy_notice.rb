class AddPrivacyNotice < ActiveRecord::Migration[8.1]
  def change
    create_table :privacy_notices do |t|
      t.text :body, null: false
      t.integer :version, null: false, default: 1
      t.timestamps
    end

    change_table :users, bulk: true do |t|
      t.integer :privacy_accepted_version
      t.datetime :privacy_accepted_at
    end
  end
end

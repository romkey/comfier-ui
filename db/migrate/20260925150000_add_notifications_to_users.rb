class AddNotificationsToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.string :slack_uid
      t.string :slack_name
      t.boolean :notify_email, default: false, null: false
      t.boolean :notify_slack, default: false, null: false
      t.boolean :notify_include_asset, default: false, null: false
    end
  end
end

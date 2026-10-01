class AddSessionEpochToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :session_epoch, :integer, default: 0, null: false
  end
end

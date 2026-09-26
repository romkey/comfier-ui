class ChangeNotificationAttachmentMaxMbToDecimal < ActiveRecord::Migration[8.1]
  def up
    change_column :app_settings, :notification_attachment_max_mb, :decimal,
                  precision: 6, scale: 2, default: 20, null: false
  end

  def down
    change_column :app_settings, :notification_attachment_max_mb, :integer, default: 20, null: false
  end
end

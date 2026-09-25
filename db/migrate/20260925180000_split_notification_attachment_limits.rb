class SplitNotificationAttachmentLimits < ActiveRecord::Migration[8.1]
  def up
    rename_column :app_settings, :notification_attachment_max_mb, :email_notification_attachment_max_mb
    add_column :app_settings, :slack_notification_attachment_max_mb, :decimal,
               precision: 6, scale: 2, null: false, default: 20

    execute <<~SQL.squish
      UPDATE app_settings
      SET slack_notification_attachment_max_mb = email_notification_attachment_max_mb
    SQL
  end

  def down
    remove_column :app_settings, :slack_notification_attachment_max_mb
    rename_column :app_settings, :email_notification_attachment_max_mb, :notification_attachment_max_mb
  end
end

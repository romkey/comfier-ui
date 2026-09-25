class UpdateNotificationAttachmentDefaults < ActiveRecord::Migration[8.1]
  def up
    change_column :app_settings, :email_notification_attachment_max_mb, :decimal,
                  precision: 8, scale: 3, default: 0.488, null: false
    change_column :app_settings, :slack_notification_attachment_max_mb, :decimal,
                  precision: 8, scale: 3, default: 5.0, null: false

    execute <<~SQL.squish
      UPDATE app_settings
      SET email_notification_attachment_max_mb = 0.488,
          slack_notification_attachment_max_mb = 5.0
      WHERE email_notification_attachment_max_mb = 20
        AND slack_notification_attachment_max_mb = 20
    SQL
  end

  def down
    change_column :app_settings, :email_notification_attachment_max_mb, :decimal,
                  precision: 6, scale: 2, default: 20, null: false
    change_column :app_settings, :slack_notification_attachment_max_mb, :decimal,
                  precision: 6, scale: 2, default: 20, null: false
  end
end

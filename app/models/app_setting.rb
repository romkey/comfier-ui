# Site-wide settings editable by admins under Settings.
class AppSetting < ApplicationRecord
  validates :notification_attachment_max_mb,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  def self.current
    first || create!(notification_attachment_max_mb: default_notification_attachment_max_mb)
  end

  def self.default_notification_attachment_max_mb
    ENV.fetch('NOTIFICATION_ATTACHMENT_MAX_MB', 20).to_i
  end

  def self.notification_attachment_max_mb = current.notification_attachment_max_mb

  def self.notification_attachment_max_bytes = notification_attachment_max_mb.megabytes
end

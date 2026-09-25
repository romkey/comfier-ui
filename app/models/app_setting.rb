# Site-wide settings editable by admins under Settings.
class AppSetting < ApplicationRecord
  ATTACHMENT_LIMIT_ATTRS = %i[email_notification_attachment_max_mb slack_notification_attachment_max_mb].freeze
  DEFAULT_EMAIL_ATTACHMENT_MB = BigDecimal('0.488') # ~500 KB
  DEFAULT_SLACK_ATTACHMENT_MB = BigDecimal('5')

  validates(*ATTACHMENT_LIMIT_ATTRS,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 })

  def self.current
    first || create!(email_notification_attachment_max_mb: default_email_notification_attachment_max_mb,
                     slack_notification_attachment_max_mb: default_slack_notification_attachment_max_mb)
  end

  def self.default_email_notification_attachment_max_mb
    env_attachment_max_mb('NOTIFICATION_EMAIL_ATTACHMENT_MAX_MB', DEFAULT_EMAIL_ATTACHMENT_MB)
  end

  def self.default_slack_notification_attachment_max_mb
    env_attachment_max_mb('NOTIFICATION_SLACK_ATTACHMENT_MAX_MB', DEFAULT_SLACK_ATTACHMENT_MB)
  end

  def self.email_notification_attachment_max_bytes
    current.email_notification_attachment_max_mb.to_d.megabytes.to_i
  end

  def self.slack_notification_attachment_max_bytes
    current.slack_notification_attachment_max_mb.to_d.megabytes.to_i
  end

  def self.env_attachment_max_mb(specific_key, fallback)
    return BigDecimal(ENV.fetch(specific_key)) if ENV.key?(specific_key)
    return BigDecimal(ENV.fetch('NOTIFICATION_ATTACHMENT_MAX_MB')) if ENV.key?('NOTIFICATION_ATTACHMENT_MAX_MB')

    fallback
  end
  private_class_method :env_attachment_max_mb
end

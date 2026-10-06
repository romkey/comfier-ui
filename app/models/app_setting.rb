# Site-wide settings editable by admins under Settings.
class AppSetting < ApplicationRecord
  ATTACHMENT_LIMIT_ATTRS = %i[email_notification_attachment_max_mb slack_notification_attachment_max_mb].freeze
  DEFAULT_EMAIL_ATTACHMENT_MB = BigDecimal('0.488') # ~500 KB
  DEFAULT_SLACK_ATTACHMENT_MB = BigDecimal('5')
  validates(*ATTACHMENT_LIMIT_ATTRS,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 })
  validates :report_auto_hide_threshold,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  CHAT_NOTICE_URL_FORMAT = %r{\Ahttps?://\S+\z}i
  validates :chat_notice_url, format: { with: CHAT_NOTICE_URL_FORMAT, allow_blank: true }
  validates :chat_default_model, length: { maximum: 255 }, allow_blank: true
  validates :session_epoch, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :motd_text, length: { maximum: 1000 }
  TIMEOUT_ATTRS = GenerationKind.keys.index_with { :"#{it}_timeout_minutes" }.freeze
  validates(*TIMEOUT_ATTRS.values, numericality: { only_integer: true, in: 1..1440 })

  normalizes :motd_text, with: ->(text) { text.to_s.strip.presence }

  def motd? = motd_text.present?

  # Identifies the current message, so dismissing it hides only this text and edits show again.
  def motd_digest
    Digest::SHA256.hexdigest(motd_text.to_s)[0, 16] if motd?
  end

  def timeout_minutes_for(kind) = public_send(TIMEOUT_ATTRS.fetch(kind.to_s))

  def chat_notice?
    chat_notice_text.present?
  end

  def allowed_chat_notice_redirect_url
    url = chat_notice_url.to_s
    return if url.blank? || !url.match?(CHAT_NOTICE_URL_FORMAT)

    uri = URI.parse(url)
    return unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

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

  def self.default_placeholder_prompt = PlaceholderSuggester::Prompt.system_prompt

  def placeholder_prompt_or_default
    placeholder_prompt.presence || self.class.default_placeholder_prompt
  end

  def using_default_placeholder_prompt?
    placeholder_prompt.blank?
  end

  def invalidate_all_sessions!
    update!(session_epoch: session_epoch + 1)
  end

  def self.env_attachment_max_mb(specific_key, fallback)
    return BigDecimal(ENV.fetch(specific_key)) if ENV.key?(specific_key)
    return BigDecimal(ENV.fetch('NOTIFICATION_ATTACHMENT_MAX_MB')) if ENV.key?('NOTIFICATION_ATTACHMENT_MAX_MB')

    fallback
  end
  private_class_method :env_attachment_max_mb
end

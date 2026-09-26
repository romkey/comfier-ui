# Site-wide settings editable by admins under Settings.
class AppSetting < ApplicationRecord
  ATTACHMENT_LIMIT_ATTRS = %i[email_notification_attachment_max_mb slack_notification_attachment_max_mb].freeze
  DEFAULT_EMAIL_ATTACHMENT_MB = BigDecimal('0.488') # ~500 KB
  DEFAULT_SLACK_ATTACHMENT_MB = BigDecimal('5')
  DEFAULT_PLACEHOLDER_PROMPT = <<~PROMPT.strip.freeze
    You help admins prepare ComfyUI workflows for Comfier, a simplified front end.

    You receive a ComfyUI workflow in API format (a JSON object whose keys are node IDs and whose values
    have class_type and inputs). Replace literal user-facing values with template placeholders so the
    studio form can fill them in at generation time.

    Rules:
    - Use only the allowed placeholders listed in the user message.
    - Each substituted value must become exactly one placeholder string, e.g. "{{prompt}}".
    - Replace positive prompt text with {{prompt}} and negative prompt text with {{negative_prompt}}.
    - Replace seed, width, height, steps, cfg, denoise, duration, frames, batch_size, lyrics and LoadImage
      image filenames when they look like user input rather than fixed workflow wiring.
    - Do not change node IDs, class_type values, model/checkpoint filenames, node links, or graph structure.
    - Do not invent placeholders that are not in the allowed list.

    Reply with JSON only, in this shape:
    {"workflow": { ...the updated API workflow... }, "notes": "Brief summary of what you changed"}
  PROMPT

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

  def placeholder_prompt_or_default
    placeholder_prompt.presence || self.class::DEFAULT_PLACEHOLDER_PROMPT
  end

  def using_default_placeholder_prompt?
    placeholder_prompt.blank?
  end

  def self.env_attachment_max_mb(specific_key, fallback)
    return BigDecimal(ENV.fetch(specific_key)) if ENV.key?(specific_key)
    return BigDecimal(ENV.fetch('NOTIFICATION_ATTACHMENT_MAX_MB')) if ENV.key?('NOTIFICATION_ATTACHMENT_MAX_MB')

    fallback
  end
  private_class_method :env_attachment_max_mb
end

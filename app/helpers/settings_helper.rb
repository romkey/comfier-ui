module SettingsHelper
  def notification_attachment_limit_label(channel)
    mb = AppSetting.current.public_send(:"#{channel}_notification_attachment_max_mb").to_d
    return '0 MB' if mb.zero?
    return "#{(mb * 1024).round} KB" if mb < 1

    precision = mb.frac.zero? ? 0 : 2
    "#{number_with_precision(mb, precision:, strip_insignificant_zeros: true)} MB"
  end

  def email_notification_note(user)
    return "Email isn't set up on this server yet." unless GenerationMailer.configured?
    return "Your sign-in account doesn't have an email address." if user.email.blank?

    "Sent to #{user.email}, from your sign-in account."
  end

  def slack_notification_note(user)
    return "Slack isn't set up on this server yet." unless SlackNotifier.configured?
    return "Your account isn't linked to Slack. Sign out and back in after it's linked." if user.slack_uid.blank?

    "Sent to #{user.slack_name.presence || 'you'} as a direct message, from your sign-in account."
  end
end

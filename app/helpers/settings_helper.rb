module SettingsHelper
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

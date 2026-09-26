class ModerationMailer < ApplicationMailer
  def owner_notice(user, title:, action:, category: nil)
    @notification = ModerationNotification.new(user, title:, action:, category:)
    mail(to: user.email, subject: @notification.subject)
  end
end

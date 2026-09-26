require 'net/smtp'

class NotifyOwnerOfModerationJob < ApplicationJob
  DELIVERY_ERRORS = NotifyAdminsOfReportJob::DELIVERY_ERRORS

  queue_as :default

  discard_on ActiveJob::DeserializationError
  retry_on(*DELIVERY_ERRORS, wait: :polynomially_longer, attempts: 5)

  def perform(user, title:, action:, category: nil)
    notification = ModerationNotification.new(user, title:, action:, category:)
    ModerationMailer.owner_notice(user, title:, action:, category:).deliver_now if user.email_reachable?
    return unless user.slack_reachable?

    SlackNotifier.direct_message(user.slack_uid, notification.slack_text)
  end
end

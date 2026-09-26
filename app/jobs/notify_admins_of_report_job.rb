require 'net/smtp'

class NotifyAdminsOfReportJob < ApplicationJob
  CHANNELS = %w[email slack].freeze
  DELIVERY_ERRORS = [
    SlackNotifier::Error, Net::SMTPServerBusy, Net::SMTPUnknownError, Net::SMTPFatalError,
    Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError
  ].freeze

  queue_as :default

  discard_on ActiveJob::DeserializationError
  retry_on(*DELIVERY_ERRORS, wait: :polynomially_longer, attempts: 5)

  def perform(report, auto_hidden: false, channel: nil)
    return fan_out(report, auto_hidden) if channel.nil?

    User.where(admin: true).find_each do |admin|
      deliver(admin, report, auto_hidden, channel)
    end
  end

  private

  def fan_out(report, auto_hidden)
    self.class.perform_later(report, auto_hidden: auto_hidden, channel: 'email') if GenerationMailer.configured?
    return unless SlackNotifier.configured?

    self.class.perform_later(report, auto_hidden: auto_hidden, channel: 'slack')
  end

  def deliver(admin, report, auto_hidden, channel)
    case channel
    when 'email'
      return if admin.email.blank?

      ReportMailer.new_report(report, admin, auto_hidden:).deliver_now
    when 'slack'
      return if admin.slack_uid.blank?

      notification = ReportNotification.new(report, auto_hidden:)
      SlackNotifier.direct_message(admin.slack_uid, notification.slack_text)
    end
  end
end

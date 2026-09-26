require 'net/smtp'

# Tells a user their generation finished. Without a channel it fans out into one job per channel
# the user turned on, so a Slack outage can't block (or re-send) the email and vice versa.
class NotifyGenerationJob < ApplicationJob
  CHANNELS = %w[email slack].freeze
  DELIVERY_ERRORS = [
    SlackNotifier::Error, Net::SMTPServerBusy, Net::SMTPUnknownError, Net::SMTPFatalError,
    Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError
  ].freeze

  queue_as :default

  discard_on ActiveJob::DeserializationError
  retry_on(*DELIVERY_ERRORS, wait: :polynomially_longer, attempts: 5) do |job, error|
    Rails.logger.warn("Gave up notifying about generation #{job.arguments.first&.id}: #{error.message}")
  end

  def perform(generation, channel = nil)
    return fan_out(generation) if channel.nil?

    user = generation.user
    Rails.logger.info("Notifying user #{user.id} by #{channel} that generation #{generation.id} #{generation.outcome}")
    case channel
    when 'email' then GenerationMailer.finished(generation).deliver_now if user.notify_via_email?
    when 'slack' then SlackNotifier.call(generation) if user.notify_via_slack?
    end
  end

  private

  def fan_out(generation)
    user = generation.user
    self.class.perform_later(generation, 'email') if user.notify_via_email?
    self.class.perform_later(generation, 'slack') if user.notify_via_slack?
  end
end

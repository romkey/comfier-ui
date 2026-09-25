# Telling the owner when a generation finishes, fails or is cancelled.
module GenerationNotifying
  extend ActiveSupport::Concern

  CANCELLED_MESSAGE = 'Cancelled'.freeze

  # Later saves in the same transaction (e.g. publishing a pending share) replace saved_changes,
  # so the finish is remembered per save rather than read back at commit time.
  included do
    after_update { @just_finished = true if saved_change_to_status? && finished? }
    after_update_commit :enqueue_finished_notification, if: -> { @just_finished }
    after_rollback { @just_finished = false }
  end

  def cancelled? = failed? && error_message == CANCELLED_MESSAGE

  # :succeeded, :failed or :cancelled — how a finished generation ended.
  def outcome
    return :cancelled if cancelled?

    status.to_sym
  end

  private

  def enqueue_finished_notification
    @just_finished = false
    return NotifyGenerationJob.perform_later(self) if user.wants_notifications?
    return unless user.notify_email? || user.notify_slack?

    Rails.logger.warn(
      "Not notifying user #{user.id} about generation #{id}: " \
      "email #{user.email_reachable? ? 'ready' : 'unavailable (no address or SMTP_ADDRESS unset)'}, " \
      "slack #{user.slack_reachable? ? 'ready' : 'unavailable (no Slack link or SLACK_BOT_TOKEN unset)'}"
    )
  end
end

# Telling the owner when a generation finishes, fails or is cancelled.
module GenerationNotifying
  extend ActiveSupport::Concern

  CANCELLED_MESSAGE = 'Cancelled'.freeze

  included do
    after_update_commit :enqueue_finished_notification, if: -> { saved_change_to_status? && finished? }
  end

  def cancelled? = failed? && error_message == CANCELLED_MESSAGE

  # :succeeded, :failed or :cancelled — how a finished generation ended.
  def outcome
    return :cancelled if cancelled?

    status.to_sym
  end

  private

  def enqueue_finished_notification
    NotifyGenerationJob.perform_later(self) if user.wants_notifications?
  end
end

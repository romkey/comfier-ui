# One "Write a script" request from the Video page. The page polls it while VideoScriptJob asks the chat model.
class VideoScriptRequest < ApplicationRecord
  MAX_ATTEMPTS = 2
  KEEP_FOR = 1.day

  belongs_to :user

  enum :status, { pending: 'pending', retrying: 'retrying', succeeded: 'succeeded', failed: 'failed',
                  cancelled: 'cancelled' }, default: :pending, validate: true

  validates :message, presence: true

  scope :stale, -> { where(created_at: ...KEEP_FOR.ago) }

  def working? = pending? || retrying?

  def attempts_left? = attempts < MAX_ATTEMPTS

  def as_json(*)
    { id:, status:, script:, error: }
  end
end

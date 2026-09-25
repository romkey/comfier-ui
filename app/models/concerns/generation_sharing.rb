# Sharing generations with everyone on the Shared gallery.
module GenerationSharing
  extend ActiveSupport::Concern

  included do
    scope :shared, -> { where.not(shared_at: nil) }
  end

  def shared? = shared_at.present?

  def share!(share_prompt: true, share_input: false)
    update!(shared_at: Time.current, share_prompt:, share_input:)
  end

  def unshare!
    update!(shared_at: nil)
  end

  def share_when_done?
    ActiveModel::Type::Boolean.new.cast(share_when_done)
  end

  # Queued with "share result" checked — publish once outputs are saved.
  def apply_pending_share!
    return unless share_when_done?

    update!(shared_at: Time.current, share_when_done: nil)
  end
end

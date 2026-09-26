# Sharing generations with everyone on the Shared gallery, and via unguessable public links.
module GenerationSharing
  extend ActiveSupport::Concern

  PUBLIC_TOKEN_BYTES = 48

  included do
    scope :shared, -> { where.not(shared_at: nil).where(hidden_for_review_at: nil) }
    scope :publicly_linked, -> { where.not(public_token: nil) }
  end

  def shared? = shared_at.present?

  def publicly_linked? = public_token.present?

  def share!
    update!(shared_at: Time.current)
  end

  def unshare!
    update!(shared_at: nil)
  end

  def create_public_link!
    update!(public_token: SecureRandom.urlsafe_base64(PUBLIC_TOKEN_BYTES), public_shared_at: Time.current)
  end

  def revoke_public_link!
    update!(public_token: nil, public_shared_at: nil)
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

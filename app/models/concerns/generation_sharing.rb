# Sharing generations with everyone on the Shared gallery, and via unguessable public links.
module GenerationSharing
  extend ActiveSupport::Concern

  PUBLIC_TOKEN_BYTES = 48

  included do
    scope :shared, -> { where.not(shared_at: nil).where(hidden_for_review_at: nil) }
    scope :shared_gallery, -> { shared.succeeded }
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

  # A new link starts counting views from zero; the old one stops working.
  def create_public_link!
    update!(public_token: SecureRandom.urlsafe_base64(PUBLIC_TOKEN_BYTES), public_shared_at: Time.current,
            public_view_count: 0, public_last_viewed_at: nil)
  end

  def revoke_public_link!
    update!(public_token: nil, public_shared_at: nil, public_view_count: 0, public_last_viewed_at: nil)
  end

  # Counted in SQL so concurrent views don't lose increments, and without touching updated_at or the
  # update callbacks that redraw the result's pages.
  def record_public_view!
    now = Time.current
    self.class.where(id:).update_all(['public_view_count = public_view_count + 1, public_last_viewed_at = ?', now]) # rubocop:disable Rails/SkipsModelValidations
    self.public_view_count += 1
    self.public_last_viewed_at = now
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

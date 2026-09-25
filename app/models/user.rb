class User < ApplicationRecord
  belongs_to :preferred_backend, class_name: 'Backend', optional: true, inverse_of: :preferring_users
  has_many :generations, dependent: :destroy

  validates :provider, :uid, presence: true
  validates :uid, uniqueness: { scope: :provider }
  validates :default_aspect_ratio, inclusion: { in: Generation::ASPECT_RATIOS }
  validate :preferred_backend_is_enabled

  def self.admin_group = ENV.fetch('AUTHENTIK_ADMIN_GROUP', 'comfier-admins')

  # Creates or refreshes a user from an OmniAuth auth hash. Admin rights follow Authentik group
  # membership on every sign-in, so removing someone from the group revokes them next login.
  def self.from_omniauth(auth)
    user = find_or_initialize_by(provider: auth.provider.to_s, uid: auth.uid.to_s)
    info = auth.info || {}
    groups = Array(auth.dig('extra', 'raw_info', 'groups'))
    slack = auth.dig('extra', 'raw_info', 'slack')
    slack = {} unless slack.is_a?(Hash)

    user.assign_attributes(
      email: info['email'],
      name: info['name'],
      username: info['nickname'],
      slack_uid: slack['uid'].presence,
      slack_name: slack['name'].presence,
      admin: groups.include?(admin_group),
      last_signed_in_at: Time.current
    )
    user.save!
    user
  end

  def display_name = name.presence || username.presence || email.presence || 'User'

  def initials
    display_name.split(/[\s@._-]+/).first(2).map(&:first).join.upcase
  end

  def email_reachable? = email.present? && GenerationMailer.configured?

  def slack_reachable? = slack_uid.present? && SlackNotifier.configured?

  def notify_via_email? = notify_email? && email_reachable?

  def notify_via_slack? = notify_slack? && slack_reachable?

  def wants_notifications? = notify_via_email? || notify_via_slack?

  def privacy_current?
    notice = PrivacyNotice.current
    privacy_accepted_version == notice.version
  end

  private

  def preferred_backend_is_enabled
    return if preferred_backend.nil? || preferred_backend.enabled?

    errors.add(:preferred_backend, 'is not available')
  end
end

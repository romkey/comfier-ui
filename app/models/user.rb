class User < ApplicationRecord
  belongs_to :preferred_backend, class_name: 'Backend', optional: true, inverse_of: :preferring_users
  has_many :generations, dependent: :destroy
  has_many :chat_conversations, dependent: :destroy
  has_many :video_script_requests, dependent: :delete_all
  has_many :owned_report_cases, class_name: 'ReportCase', foreign_key: :owner_id, dependent: :nullify,
                                inverse_of: :owner
  has_many :reviewed_report_cases, class_name: 'ReportCase', foreign_key: :reviewed_by_id, dependent: :nullify,
                                   inverse_of: :reviewed_by

  has_many :owned_backends, class_name: 'Backend', foreign_key: :owner_user_id, dependent: :nullify,
                            inverse_of: :owner_user
  has_many :backend_shares, dependent: :delete_all
  has_many :shared_backends, through: :backend_shares, source: :backend
  has_many :source_credentials, foreign_key: :owner_user_id, dependent: :delete_all, inverse_of: :owner_user

  BACKEND_AFFINITIES = {
    'auto' => 'Fastest available', 'prefer_mine' => 'Prefer my servers',
    'mine_only' => 'Only my servers', 'any' => 'Any server'
  }.freeze

  validates :provider, :uid, presence: true
  validates :backend_affinity, inclusion: { in: BACKEND_AFFINITIES.keys }
  validates :uid, uniqueness: { scope: :provider }
  validates :default_aspect_ratio, inclusion: { in: Generation::ASPECT_RATIOS }
  validate :preferred_backend_is_enabled

  def self.admin_group = ENV.fetch('AUTHENTIK_ADMIN_GROUP', 'comfier-admins')

  # Whether the site's message of the day should show for this user.
  def sees_motd?(settings = AppSetting.current)
    settings.motd? && dismissed_motd_digest != settings.motd_digest
  end

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

  def display_name = username.presence || name.presence || email.presence || 'User'

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

  def revoke_all_public_links!
    generations.publicly_linked.update_all(public_token: nil, public_shared_at: nil, public_view_count: 0, # rubocop:disable Rails/SkipsModelValidations
                                           public_last_viewed_at: nil, updated_at: Time.current)
  end

  private

  def preferred_backend_is_enabled
    return if preferred_backend.nil? || preferred_backend.enabled?

    errors.add(:preferred_backend, 'is not available')
  end
end

# A single configured account for development. Only ever enabled in the development environment
# (see config/initializers/dev_login.rb), and only once both an email and a password are set.
module DevLogin
  def self.config = Rails.application.config.x.dev_login || {}

  def self.requested? = config.present?
  def self.enabled? = config[:email].present? && config[:password].present?

  def self.authenticate(email, password)
    return false unless enabled?

    email_ok = ActiveSupport::SecurityUtils.secure_compare(email.to_s.strip.downcase, config[:email])
    password_ok = ActiveSupport::SecurityUtils.secure_compare(password.to_s, config[:password])
    email_ok && password_ok
  end

  # The account is re-synced from the config on every sign-in, like Authentik users are.
  def self.user
    notice = PrivacyNotice.current
    user = User.find_or_initialize_by(provider: 'developer', uid: config[:email])
    user.update!(email: config[:email], name: config[:name], admin: config[:admin], last_signed_in_at: Time.current,
                 privacy_accepted_version: notice.version, privacy_accepted_at: Time.current)
    user
  end
end

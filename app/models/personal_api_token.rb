# Personal tokens authenticate user API requests; the secret is shown only when issued.
class PersonalApiToken < ApplicationRecord
  PREFIX = 'cmfu_'.freeze
  TOKEN_PATTERN = /\Acmfu_[0-9a-f]{64}\z/

  belongs_to :user

  validates :name, presence: true, length: { maximum: 100 }
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true

  scope :active, -> { where(revoked_at: nil) }

  def self.issue!(user:, name:)
    secret = "#{PREFIX}#{SecureRandom.hex(32)}"
    token = create!(user:, name:, token_digest: Digest::SHA256.hexdigest(secret), token_prefix: secret.first(13))
    [token, secret]
  end

  def self.authenticate(secret)
    return unless secret.is_a?(String) && TOKEN_PATTERN.match?(secret)

    active.includes(:user).find_by(token_digest: Digest::SHA256.hexdigest(secret))
  end

  def revoke! = update!(revoked_at: revoked_at || Time.current)

  def revoked? = revoked_at.present?

  def display = "#{token_prefix}…"
end

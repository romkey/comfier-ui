# Append-only audit trail for sign-ins, generations, and LLM calls.
class ActivityLog < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  enum :kind, {
    login: 'login',
    login_failed: 'login_failed',
    logout: 'logout',
    generation_queued: 'generation_queued',
    generation_succeeded: 'generation_succeeded',
    generation_failed: 'generation_failed',
    generation_cancelled: 'generation_cancelled',
    llm_chat: 'llm_chat',
    server_registered: 'server_registered',
    server_updated: 'server_updated',
    server_deleted: 'server_deleted',
    server_paused: 'server_paused',
    server_resumed: 'server_resumed',
    server_shared: 'server_shared',
    server_unshared: 'server_unshared',
    server_converted: 'server_converted',
    server_key_created: 'server_key_created',
    server_key_rotated: 'server_key_rotated',
    server_key_revoked: 'server_key_revoked',
    model_download_requested: 'model_download_requested',
    model_download_cancelled: 'model_download_cancelled',
    source_credential_saved: 'source_credential_saved',
    source_credential_deleted: 'source_credential_deleted',
    media_failed: 'media_failed'
  }, validate: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  scope :search, lambda { |query|
    term = query.to_s.strip
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term)}%"
    where_clause = <<~SQL.squish
      activity_logs.message ILIKE :q OR activity_logs.ip_address ILIKE :q
      OR CAST(activity_logs.details AS text) ILIKE :q
      OR users.email ILIKE :q OR users.name ILIKE :q OR users.username ILIKE :q
    SQL
    left_joins(:user).where(where_clause, q: pattern).distinct
  }

  def self.record(kind:, message:, **options)
    create!(
      kind:,
      user: options[:user],
      subject: options[:subject],
      message: message.to_s.truncate(500),
      details: options.fetch(:details, {}).presence || {},
      ip_address: options[:request]&.remote_ip,
      user_agent: options[:request]&.user_agent&.truncate(1000)
    )
  rescue StandardError => e
    Rails.logger.error("ActivityLog.record failed (#{kind}): #{e.class}: #{e.message}")
    nil
  end

  def self.record_generation_queued(generation) = GenerationEvents.record_queued(generation)

  def self.record_generation_finished(generation) = GenerationEvents.record_finished(generation)
end

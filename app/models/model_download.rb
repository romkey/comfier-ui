# One model file being downloaded onto one backend, either by running the Comfier downloader node
# as a tiny workflow or by queueing it in ComfyUI-Manager.
class ModelDownload < ApplicationRecord
  enum :status, { queued: 'queued', running: 'running', succeeded: 'succeeded', failed: 'failed' },
       default: :queued, validate: true
  enum :via, { node: 'node', manager: 'manager' }, validate: { allow_nil: true }

  belongs_to :backend

  validates :directory, :name, :url, presence: true
  validate :requirement_is_valid

  scope :active, -> { where(status: %i[queued running]) }
  scope :recent, -> { order(created_at: :desc) }

  after_commit -> { broadcast_refresh_later_to :model_downloads }

  def self.timeout = ENV.fetch('MODEL_DOWNLOAD_TIMEOUT_HOURS', 12).to_i.hours

  def requirement = ModelRequirement.new(directory:, name:, url:)

  def active? = queued? || running?

  def timed_out? = (started_at || created_at) < self.class.timeout.ago

  def fail!(message)
    update!(status: :failed, error_message: message.to_s.truncate(1000), finished_at: Time.current)
  end

  def succeed!
    update!(status: :succeeded, error_message: nil, finished_at: Time.current)
  end

  # A one-node workflow that makes the backend fetch this file itself.
  def downloader_graph
    { '1' => { 'class_type' => Comfyui::Client::DOWNLOADER_NODE,
               'inputs' => { 'url' => url, 'directory' => directory, 'filename' => name } } }
  end

  private

  def requirement_is_valid
    requirement.problems.each { errors.add(:base, it) }
  end
end

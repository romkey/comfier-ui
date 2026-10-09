# One model file being downloaded onto one backend, either by running the Comfier downloader node
# as a tiny workflow or by queueing it in ComfyUI-Manager. For the mflux and MLX video engines it's a whole
# model, by name (directory is the engine, name the model), which the engine fetches itself: no url.
class ModelDownload < ApplicationRecord
  enum :status, { queued: 'queued', running: 'running', succeeded: 'succeeded', failed: 'failed' },
       default: :queued, validate: true
  enum :via, { node: 'node', manager: 'manager', agent: 'agent' }, validate: { allow_nil: true }

  belongs_to :backend
  belongs_to :requested_by_user, class_name: 'User', optional: true

  scope :agent_pending, -> { where(agent_state: Agent::DownloadSender::PENDING) }

  def agent_progress
    return unless bytes_total.to_i.positive?

    (bytes_done.to_f / bytes_total).clamp(0, 1)
  end

  def agent_eta = Agent::DownloadSender.eta(self)

  def cancellable?
    agent? ? Agent::DownloadSender::PENDING.include?(agent_state) && agent_state != 'cancelling' : false
  end

  validates :directory, :name, presence: true
  validates :url, presence: true, unless: :engine?
  validate :requirement_is_valid, unless: :engine?

  scope :active, -> { where(status: %i[queued running]) }
  scope :finished, -> { where(agent_state: %w[completed failed cancelled]) }
  scope :recent, -> { order(created_at: :desc) }

  after_commit :broadcast_download_refreshes

  def broadcast_download_refreshes
    broadcast_refresh_later_to(:model_downloads, target: 'workflow_models')
    broadcast_refresh_later_to([backend, :downloads], target: "server_downloads_#{backend.id}")
  end

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

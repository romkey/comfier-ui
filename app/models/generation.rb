# One request to generate media, and whatever ComfyUI produced for it.
class Generation < ApplicationRecord
  include GenerationParameters
  include GenerationSharing
  include GenerationContentReports
  include GenerationTiming
  include GenerationNotifying

  ASPECT_RATIO_LABELS = {
    '1:1' => 'Square', '4:3' => 'Landscape', '3:4' => 'Portrait', '16:9' => 'Wide', '9:16' => 'Tall'
  }.freeze
  ASPECT_RATIOS = ASPECT_RATIO_LABELS.keys.freeze
  DURATION_RANGE = (1..30)
  MAX_SEED = (2**32) - 1
  QUALITIES = %w[fast standard best].freeze
  CFG_LEVELS = %w[loose balanced strict].freeze
  BATCH_RANGE = (1..4)
  DENOISE_RANGE = (0.1..1.0)

  enum :kind, GenerationKind.enum_values, validate: { allow_nil: true }
  enum :status, { queued: 'queued', running: 'running', succeeded: 'succeeded', failed: 'failed' },
       default: :queued, validate: true

  belongs_to :user
  belongs_to :workflow, optional: true
  belongs_to :backend, optional: true

  has_many_attached :outputs
  has_one_attached :input_image

  store_accessor :parameters, :seed, :aspect_ratio, :width, :height, :duration, :frames,
                 :quality, :cfg_level, :denoise, :lyrics, :batch_size, :steps, :cfg, :share_when_done

  validates :workflow, presence: true, on: :create
  validates :prompt, presence: true, if: -> { workflow&.uses?(:prompt) }
  validates :lyrics, presence: true, if: -> { workflow&.uses?(:lyrics) }
  validates :prompt, :negative_prompt, :lyrics, length: { maximum: 10_000 }
  validate :input_image_present, on: :create
  validate :workflow_is_usable, on: :create

  before_validation :resolve_parameters, on: :create
  before_validation :snapshot_workflow_name, on: :create

  after_create_commit -> { broadcast_prepend_later_to [user, :generations], target: "#{kind}_generations" }
  after_update_commit -> { broadcast_replace_later_to [user, :generations] }
  after_update_commit -> { broadcast_refresh_later_to self }
  after_update_commit :cleanup_backend_run, if: :saved_change_to_status?
  after_commit -> { broadcast_queue_updates }
  after_destroy_commit -> { broadcast_remove_to [user, :generations] }

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  scope :finished, -> { where(status: %i[succeeded failed]) }
  scope :in_progress, -> { where(status: %i[queued running]) }

  def kind_info = GenerationKind.find(kind)

  def finished? = succeeded? || failed?

  def in_progress? = queued? || running?

  def timed_out?(limit = self.class.timeout)
    (submitted_at || created_at) < limit.ago
  end

  def self.timeout = ENV.fetch('GENERATION_TIMEOUT_MINUTES', 60).to_i.minutes

  def fail!(message)
    update!(status: :failed, error_message: message.to_s.truncate(1000), completed_at: Time.current)
  end

  def succeed!
    update!(status: :succeeded, error_message: nil, completed_at: Time.current)
  end

  def style_name = workflow_name.presence || workflow&.name || 'Removed'

  def placeholder_values(image: nil)
    {
      'prompt' => prompt.to_s, 'negative_prompt' => negative_prompt.to_s, 'seed' => seed,
      'width' => width, 'height' => height, 'duration' => duration, 'frames' => frames, 'image' => image,
      'steps' => steps, 'cfg' => cfg, 'denoise' => denoise, 'lyrics' => lyrics.to_s, 'batch_size' => batch_size
    }.compact
  end

  def reusable_attributes
    { workflow_id:, prompt:, negative_prompt:, aspect_ratio:, duration:, quality:, cfg_level:, denoise:, lyrics:,
      batch_size: }.compact
  end

  def title = prompt.presence&.truncate(80) || input_image&.filename&.to_s || "#{kind_info.label} ##{id}"

  def self.dimensions_for(aspect_ratio, base_resolution)
    ratio_w, ratio_h = aspect_ratio.split(':').map(&:to_f)
    area = base_resolution.to_f**2
    width = Math.sqrt(area * ratio_w / ratio_h)
    [snap(width), snap(width * ratio_h / ratio_w)]
  end

  def self.snap(value) = [(value / 64).round * 64, 64].max

  def cleanup_backend_run
    return unless finished?

    Comfyui::GenerationCleaner.call(self)
  end

  private

  def snapshot_workflow_name
    self.workflow_name = workflow&.name if workflow
  end

  def broadcast_queue_updates
    return unless in_progress? || saved_change_to_status?

    count = Generation.in_progress.count
    Turbo::StreamsChannel.broadcast_replace_later_to(:queue, target: 'queue_count', partial: 'queue/count',
                                                             locals: { count: })
    Turbo::StreamsChannel.broadcast_refresh_later_to(:queue)
  end

  def input_image_present
    return unless workflow&.uses?(:image)

    errors.add(:input_image, 'is required') unless input_image.attached?
  end

  def workflow_is_usable
    return if workflow.nil?

    errors.add(:workflow, 'is not available') unless workflow.enabled?
  end
end

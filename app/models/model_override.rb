# A server's own version of a model file a workflow names: jobs for the workflow that run on that server download
# and load the replacement instead, say an fp16 file where fp8 gives noise, or a GGUF where the full model doesn't
# fit. Without a workflow it applies to every workflow on the server that uses the file; one for the workflow wins.
# Only agent servers use overrides.
class ModelOverride < ApplicationRecord
  ROUTING_ATTRIBUTES = %w[workflow_id folder filename replacement_folder replacement_filename url].freeze
  FILE_DETAILS = %w[bytes sha256].freeze

  belongs_to :backend
  belongs_to :workflow, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  normalizes :folder, :replacement_folder, :note, with: ->(value) { value.to_s.strip.presence }
  normalizes :filename, :replacement_filename, with: ->(value) { value.to_s.strip.tr('\\', '/').presence }
  normalizes :url, with: ->(value) { ModelRequirement.new(directory: 'x', name: 'x', url: value).url }
  normalizes :sha256, with: ->(value) { value.to_s.strip.downcase.presence }

  validates :folder, :filename, :replacement_filename, presence: true
  validates :filename, uniqueness: { scope: %i[backend_id workflow_id folder], message: 'already has an override' }
  validates :sha256, format: { with: /\A\h{64}\z/, message: 'must be 64 hexadecimal characters' }, allow_nil: true
  validates :bytes, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :note, length: { maximum: 200 }
  validate :replacement_is_another_file
  validate :files_are_valid

  before_save :forget_old_file, if: -> { persisted? && will_save_change_to_url? }
  after_commit :refresh_routing, if: :routing_changed?
  after_commit :refresh_file_details, on: :update, if: :file_details_changed?
  after_commit :enrich, on: %i[create update], if: -> { url.present? && bytes.nil? && saved_change_to_url? }

  scope :ordered, -> { order(:folder, :filename, :workflow_id) }

  def server_wide? = workflow_id.nil?
  def target_folder = replacement_folder || folder
  def path = "#{folder}/#{filename}"
  def replacement_path = "#{target_folder}/#{replacement_filename}"
  def replacement = ModelRequirement.new(directory: target_folder, name: replacement_filename, url:)

  # Whether this overrides a model a workflow names: the same file in the same folder, allowing for the folders
  # ComfyUI treats as one (unet is diffusion_models), or in any folder when the workflow's couldn't be worked out.
  def applies_to?(model)
    return false unless model['filename'].to_s.tr('\\', '/') == filename

    model['folder'] == 'unknown' || Agent::ModelMatcher.folders_for(folder).include?(model['folder'])
  end

  # The model as the server gets it: the replacement's folder, name, link, checksum and size. It keeps no fp16 link,
  # so on a Mac the replacement is only swapped again when it is fp8 itself (see Agent::MacWeights).
  def stand_in(model)
    model.except('fp16_url', 'fp16_bytes', 'fp16_sha256', 'convert', 'replaces')
         .merge('folder' => target_folder, 'filename' => replacement_filename, 'url' => url, 'sha256' => sha256,
                'bytes' => bytes, 'overrides' => "#{model['folder']}/#{model['filename']}")
  end

  private

  def replacement_is_another_file
    return unless replacement_filename == filename && ModelRequirement::DIRECTORY.match?(target_folder.to_s) &&
                  Agent::ModelMatcher.folders_for(folder).include?(target_folder)

    errors.add(:replacement_filename, 'must be a different file')
  end

  def files_are_valid
    return if folder.blank? || filename.blank? || replacement_filename.blank?

    problems = ModelRequirement.new(directory: folder, name: filename).problems + replacement.problems
    problems.uniq.each { errors.add(:base, it) }
  end

  def routing_changed?
    destroyed? || previously_new_record? || saved_changes.keys.intersect?(ROUTING_ATTRIBUTES)
  end

  # A new link is another file: its size and checksum are looked up again unless they come with it.
  def forget_old_file
    self.bytes = nil unless will_save_change_to_bytes?
    self.sha256 = nil unless will_save_change_to_sha256?
  end

  def file_details_changed? = !routing_changed? && saved_changes.keys.intersect?(FILE_DETAILS)

  def refresh_routing
    RecomputeAvailabilityJob.perform_later(backend_id:)
    Agent::ModelOverrides.replan_jobs!(backend, workflow_ids: affected_workflow_ids)
  end

  # The workflows a change affects, before and after a change of scope; nil when that includes every workflow.
  def affected_workflow_ids
    ids = [workflow_id]
    ids << workflow_id_before_last_save if !destroyed? && !previously_new_record? && saved_change_to_workflow_id?
    ids.include?(nil) ? nil : ids.uniq
  end

  # A size or checksum found after the replacement was queued: availability counts it, and queued downloads of it
  # check it and know how much disk they need. On a Mac an fp8 replacement is queued under its converted name,
  # still fetched from the same link, so the size and checksum describe what it downloads too.
  def refresh_file_details
    RecomputeAvailabilityJob.perform_later(backend_id:)
    details = { bytes_total: bytes, sha256: }.compact
    return if details.empty?

    mac = Agent::MacWeights
    names = [replacement_filename]
    names << mac.converted_name(replacement_filename) if mac.convertible?(replacement_filename)
    backend.model_downloads.where(agent_state: 'queued', directory: target_folder, name: names, url:)
           .update_all(details) # rubocop:disable Rails/SkipsModelValidations
  end

  def enrich = EnrichModelOverrideJob.perform_later(self)
end

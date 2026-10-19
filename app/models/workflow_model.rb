# One model file a workflow needs, normalized from the API and UI forms. Admin edits (source
# "admin") win over re-extracted rows for the same folder and filename.
class WorkflowModel < ApplicationRecord
  SOURCES = %w[api ui admin enriched].freeze

  belongs_to :workflow

  validates :folder, :filename, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :filename, uniqueness: { scope: %i[workflow_id folder] }

  def requirement = ModelRequirement.new(directory: folder, name: filename, url:)
  def basename = File.basename(filename)
  def unknown_folder? = folder == 'unknown'

  def to_requirement_h
    { 'folder' => folder, 'filename' => filename, 'url' => url, 'sha256' => sha256, 'bytes' => bytes,
      'source' => source }.merge(fp16_h)
  end

  private

  # Where the official fp16 version of an fp8 file is, for Apple Silicon (see Agent::MacWeights).
  def fp16_h
    return {} if fp16_url.blank?

    { 'fp16_url' => fp16_url, 'fp16_bytes' => fp16_bytes, 'fp16_sha256' => fp16_sha256 }.compact
  end
end

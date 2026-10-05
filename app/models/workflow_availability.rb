# Cached answer to "can this server run this workflow?", recomputed when either side changes.
class WorkflowAvailability < ApplicationRecord
  STATUSES = %w[ready needs_downloads blocked].freeze

  belongs_to :workflow
  belongs_to :backend

  validates :status, inclusion: { in: STATUSES }

  def ready? = status == 'ready'
  def needs_downloads? = status == 'needs_downloads'
  def blocked? = status == 'blocked'

  def download_progress_label
    return unless needs_downloads?

    missing = Array(details['models']).size
    total = details['required_model_count'].to_i
    total = missing if total < missing
    present = total - missing
    return "#{present} of #{total} downloaded" if total.positive?

    'Needs downloads'
  end

  def download_progress_title
    return unless needs_downloads?

    bytes = details['total_bytes']
    return unless bytes

    "#{ActiveSupport::NumberHelper.number_to_human_size(bytes.to_i, precision: 2)} still to download"
  end
end

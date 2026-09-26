class ReportCase < ApplicationRecord
  enum :status, { open: 'open', reviewed: 'reviewed' }, validate: true
  enum :conclusion, { removed: 'removed', okay: 'okay' }, validate: { allow_nil: true }

  belongs_to :generation, optional: true
  belongs_to :owner, class_name: 'User'
  belongs_to :reviewed_by, class_name: 'User', optional: true
  has_many :reports, dependent: :destroy

  scope :recent, -> { order(created_at: :desc) }
  scope :open_cases, -> { where(status: :open) }

  validates :generation_title, presence: true

  # Records a report, dedupes repeat reporters, and may auto-hide the generation.
  def self.record!(generation, attrs)
    result = { report: nil, created: false, auto_hidden: false }
    transaction do
      report_case = open_cases.find_by(generation_id: generation.id)
      report_case ||= create!(
        generation:,
        generation_title: generation.title,
        owner_id: generation.user_id,
        status: :open
      )

      return result if report_case.reports.exists?(reporter_digest: attrs.fetch(:reporter_digest))

      normalized = attrs.merge(generation:, source: attrs[:source].to_s)
      report = report_case.reports.create!(normalized)
      report_case.increment!(:reports_count) # rubocop:disable Rails/SkipsModelValidations
      result[:report] = report
      result[:created] = true
      result[:auto_hidden] = auto_hidden_by_threshold?(generation, report_case)
    end
    result
  end

  def self.auto_hidden_by_threshold?(generation, report_case)
    threshold = AppSetting.current.report_auto_hide_threshold
    return false if threshold.zero?
    return false if generation.hidden_for_review?

    distinct = report_case.reports.distinct.count(:reporter_digest)
    return false if distinct < threshold

    generation.hide_for_review!
    true
  end
  private_class_method :auto_hidden_by_threshold?

  def review!(reviewer:, conclusion:, review_note: nil, delete_generation: false)
    transaction do
      generation&.tap do |gen|
        if conclusion == 'removed'
          gen.unshare!
          gen.revoke_public_link! if gen.publicly_linked?
          gen.destroy! if delete_generation
        elsif conclusion == 'okay'
          gen.clear_review_hide!
        end
      end

      update!(
        status: :reviewed,
        conclusion:,
        review_note: review_note.presence,
        reviewed_by: reviewer,
        reviewed_at: Time.current
      )
    end
  end

  def display_title
    generation&.title || generation_title
  end

  def latest_report
    reports.order(created_at: :desc).first
  end
end

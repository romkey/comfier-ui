# Content reports and moderation visibility for a generation.
module GenerationContentReports
  extend ActiveSupport::Concern

  included do
    has_many :report_cases, dependent: :nullify
    has_many :reports, dependent: :nullify
  end

  def hidden_for_review? = hidden_for_review_at.present?

  def hide_for_review!
    update!(hidden_for_review_at: Time.current) unless hidden_for_review?
  end

  def clear_review_hide!
    update!(hidden_for_review_at: nil) if hidden_for_review?
  end
end

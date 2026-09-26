module ReportSubmission
  extend ActiveSupport::Concern

  HONEYPOT_PARAM = :company_website

  included do
    unless Rails.env.test?
      rate_limit to: 5, within: 1.hour, by: -> { request.remote_ip }, only: :create, with: :report_rate_limited
      rate_limit to: 20, within: 1.day, by: -> { request.remote_ip }, only: :create, with: :report_rate_limited
    end
  end

  private

  def submit_report(generation, source:, return_to:, reporter_id: nil)
    return honeypot_thanks(return_to) if params[HONEYPOT_PARAM].present?

    result = record_report(generation, source:, reporter_id:)
    unless result
      return redirect_to return_to, alert: 'Please choose a category and describe the problem.', status: :see_other
    end

    enqueue_admin_notice(result) if result[:created] && result[:report]
    redirect_to return_to, notice: 'Thanks. An admin will review it.', status: :see_other
  rescue ActiveRecord::RecordInvalid
    redirect_to return_to, alert: 'Please choose a category and describe the problem.', status: :see_other
  end

  def honeypot_thanks(return_to)
    redirect_to return_to, notice: 'Thanks. An admin will review it.', status: :see_other
  end

  def record_report(generation, source:, reporter_id:)
    report_params = params.expect(report: %i[category reason contact_email])
    category = report_params[:category].presence_in(Report::CATEGORIES.keys)
    return nil unless category

    digest = Report.digest_for(reporter_id:, ip: request.remote_ip)
    ReportCase.record!(
      generation,
      category:,
      reason: report_params[:reason],
      contact_email: report_params[:contact_email],
      reporter_id:,
      source: source.to_s,
      reporter_digest: digest
    )
  end

  def enqueue_admin_notice(result)
    NotifyAdminsOfReportJob.perform_later(result[:report], auto_hidden: result[:auto_hidden])
  end

  def report_rate_limited
    redirect_to root_path, alert: 'Too many reports. Try again later.', status: :see_other
  end
end

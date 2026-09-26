# Admin alert content for a new content report. Never includes the asset or links to it.
class ReportNotification
  attr_reader :report, :auto_hidden

  def initialize(report, auto_hidden: false)
    @report = report
    @auto_hidden = auto_hidden
    @case = report.report_case
  end

  def headline = 'New content report'

  def subject = "#{headline} · #{report.category_label}"

  def admin_url
    base = ENV.fetch('APP_URL', 'http://localhost:3000').chomp('/')
    path = Rails.application.routes.url_helpers.admin_report_path(@case)
    "#{base}#{path}"
  end

  def source_label
    return 'Public link' if report.public?

    report.reporter&.display_name || 'Member'
  end

  def report_number_label
    n = @case.reports_count
    suffix = { 1 => 'st', 2 => 'nd', 3 => 'rd' }.fetch(n, 'th')
    "#{n}#{suffix} report"
  end

  def lines
    [
      "*Category:* #{report.category_label}",
      "*Reason:* #{report.reason}",
      "*From:* #{source_label}",
      ("*Contact:* #{report.contact_email}" if report.contact_email.present?),
      "*Case:* #{report_number_label} on \"#{@case.display_title}\"",
      ('*Auto-hidden from sharing.*' if auto_hidden),
      "<#{admin_url}|Review in Comfier>"
    ].compact
  end

  def slack_text = lines.join("\n")
end

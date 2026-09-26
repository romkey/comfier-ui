class ReportMailer < ApplicationMailer
  def new_report(report, admin, auto_hidden: false)
    @notification = ReportNotification.new(report, auto_hidden:)
    mail(to: admin.email, subject: @notification.subject)
  end
end

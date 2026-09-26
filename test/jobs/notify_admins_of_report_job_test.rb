require 'test_helper'

class NotifyAdminsOfReportJobTest < ActiveJob::TestCase
  setup do
    @report = reports(:alice_report)
    ActionMailer::Base.deliveries.clear
  end

  test 'emails every admin when configured' do
    with_env('SMTP_ADDRESS' => 'smtp.test') do
      admin_count = User.where(admin: true).where.not(email: [nil, '']).count
      assert_difference -> { ActionMailer::Base.deliveries.size }, admin_count do
        NotifyAdminsOfReportJob.perform_now(@report, channel: 'email')
      end
    end
  end

  test 'email body includes reason and no attachment' do
    with_env('SMTP_ADDRESS' => 'smtp.test') do
      NotifyAdminsOfReportJob.perform_now(@report, channel: 'email')
      mail = ActionMailer::Base.deliveries.last

      assert_includes mail.body.encoded, @report.reason
      assert_not_includes mail.body.encoded, '/p/'
      assert_empty mail.attachments
    end
  end
end

require 'test_helper'

class NotifyGenerationJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @user = users(:alice)
    @generation = generations(:alice_done)
  end

  test 'fans out into one job per channel the user turned on' do
    @user.update!(notify_email: true, notify_slack: true, slack_uid: 'U123')

    with_notifications_configured do
      assert_enqueued_with(job: NotifyGenerationJob, args: [@generation, 'email']) do
        assert_enqueued_with(job: NotifyGenerationJob, args: [@generation, 'slack']) do
          NotifyGenerationJob.perform_now(@generation)
        end
      end
    end
  end

  test 'skips channels that are off or unavailable' do
    @user.update!(notify_email: false, notify_slack: true)

    with_notifications_configured do
      assert_no_enqueued_jobs(only: NotifyGenerationJob) { NotifyGenerationJob.perform_now(@generation) }
    end
  end

  test 'sends the email' do
    @user.update!(notify_email: true)

    with_notifications_configured do
      assert_emails(1) { NotifyGenerationJob.perform_now(@generation, 'email') }
    end
  end

  test 'sends nothing when the user has the channel off' do
    with_notifications_configured do
      assert_emails(0) { NotifyGenerationJob.perform_now(@generation, 'email') }
    end
  end

  test 'retries when Slack fails' do
    @user.update!(notify_slack: true, slack_uid: 'U123')
    stub_request(:post, 'https://slack.com/api/conversations.open').to_return(status: 500)

    with_notifications_configured do
      assert_enqueued_with(job: NotifyGenerationJob, args: [@generation, 'slack']) do
        NotifyGenerationJob.perform_now(@generation, 'slack')
      end
    end
  end
end

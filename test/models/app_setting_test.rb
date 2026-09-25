require 'test_helper'

class AppSettingTest < ActiveSupport::TestCase
  test 'current returns the configured row' do
    app_settings(:default).update!(email_notification_attachment_max_mb: 15)

    assert_equal 15, AppSetting.current.email_notification_attachment_max_mb
    assert_equal 15.megabytes, AppSetting.email_notification_attachment_max_bytes
  end

  test 'rejects negative attachment limits' do
    settings = app_settings(:default)

    assert_not settings.update(email_notification_attachment_max_mb: -1)
    assert_not settings.update(slack_notification_attachment_max_mb: -1)
  end

  test 'allows zero to disable attachments' do
    app_settings(:default).update!(email_notification_attachment_max_mb: 0, slack_notification_attachment_max_mb: 0)

    assert_equal 0, AppSetting.email_notification_attachment_max_bytes
    assert_equal 0, AppSetting.slack_notification_attachment_max_bytes
  end

  test 'supports fractional megabyte limits' do
    app_settings(:default).update!(email_notification_attachment_max_mb: 0.5)

    assert_in_delta 0.5, AppSetting.current.email_notification_attachment_max_mb
    assert_equal 512.kilobytes, AppSetting.email_notification_attachment_max_bytes
  end
end

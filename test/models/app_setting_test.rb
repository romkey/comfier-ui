require 'test_helper'

class AppSettingTest < ActiveSupport::TestCase
  test 'current returns the configured row' do
    app_settings(:default).update!(notification_attachment_max_mb: 15)

    assert_equal 15, AppSetting.current.notification_attachment_max_mb
    assert_equal 15, AppSetting.notification_attachment_max_mb
  end

  test 'rejects negative attachment limits' do
    settings = app_settings(:default)

    assert_not settings.update(notification_attachment_max_mb: -1)
  end

  test 'allows zero to disable attachments' do
    app_settings(:default).update!(notification_attachment_max_mb: 0)

    assert_equal 0, AppSetting.notification_attachment_max_mb
  end
end

require 'test_helper'

module Admin
  class AppSettingsTest < ActionDispatch::IntegrationTest
    test 'non-admins cannot edit notification settings' do
      sign_in_as users(:alice)

      get edit_admin_app_setting_path

      assert_response :not_found

      patch admin_app_setting_path, params: {
        app_setting: { email_notification_attachment_max_mb: 5, slack_notification_attachment_max_mb: 5 }
      }

      assert_response :not_found
      assert_in_delta 0.488, app_settings(:default).reload.email_notification_attachment_max_mb
    end

    test 'admins can update the attachment size limits' do
      sign_in_as users(:admin)

      get edit_admin_app_setting_path

      assert_response :success
      assert_select 'h1', text: 'Notifications'
      assert_select 'input[name="app_setting[email_notification_attachment_max_mb]"][value="0.488"]'
      assert_select 'input[name="app_setting[slack_notification_attachment_max_mb]"][value="5.0"]'

      patch admin_app_setting_path, params: {
        app_setting: { email_notification_attachment_max_mb: 8, slack_notification_attachment_max_mb: 0.5 }
      }

      assert_redirected_to edit_admin_app_setting_path
      settings = app_settings(:default).reload

      assert_in_delta 8, settings.email_notification_attachment_max_mb
      assert_in_delta 0.5, settings.slack_notification_attachment_max_mb
    end

    test 'rejects invalid attachment size limits' do
      sign_in_as users(:admin)

      patch admin_app_setting_path, params: {
        app_setting: { email_notification_attachment_max_mb: 500, slack_notification_attachment_max_mb: 20 }
      }

      assert_response :unprocessable_content
      assert_in_delta 0.488, app_settings(:default).reload.email_notification_attachment_max_mb
    end
  end
end

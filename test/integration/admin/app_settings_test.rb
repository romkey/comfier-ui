require 'test_helper'

module Admin
  class AppSettingsTest < ActionDispatch::IntegrationTest
    test 'non-admins cannot edit notification settings' do
      sign_in_as users(:alice)

      get edit_admin_app_setting_path

      assert_response :not_found

      patch admin_app_setting_path, params: { app_setting: { notification_attachment_max_mb: 5 } }

      assert_response :not_found
      assert_equal 20, app_settings(:default).reload.notification_attachment_max_mb
    end

    test 'admins can update the attachment size limit' do
      sign_in_as users(:admin)

      get edit_admin_app_setting_path

      assert_response :success
      assert_select 'h1', text: 'Notifications'
      assert_select 'input[name="app_setting[notification_attachment_max_mb]"][value="20.0"]'

      patch admin_app_setting_path, params: { app_setting: { notification_attachment_max_mb: 0.5 } }

      assert_redirected_to edit_admin_app_setting_path
      assert_in_delta 0.5, app_settings(:default).reload.notification_attachment_max_mb
    end

    test 'rejects invalid attachment size limits' do
      sign_in_as users(:admin)

      patch admin_app_setting_path, params: { app_setting: { notification_attachment_max_mb: 500 } }

      assert_response :unprocessable_content
      assert_equal 20, app_settings(:default).reload.notification_attachment_max_mb
    end
  end
end

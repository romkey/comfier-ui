require 'test_helper'

module Admin
  class TimeLimitsTest < ActionDispatch::IntegrationTest
    test 'non-admins cannot edit time limits' do
      sign_in_as users(:alice)

      get edit_admin_time_limits_path

      assert_response :not_found
    end

    test 'admins can update the time limits' do
      sign_in_as users(:admin)

      get edit_admin_time_limits_path

      assert_response :success
      assert_select 'input[name="app_setting[video_timeout_minutes]"][value="240"]'

      patch admin_time_limits_path, params: { app_setting: { video_timeout_minutes: 300, image_timeout_minutes: 0 } }

      assert_response :unprocessable_content
      patch admin_time_limits_path, params: { app_setting: { video_timeout_minutes: 300 } }

      assert_redirected_to edit_admin_time_limits_path
      assert_equal 300, app_settings(:default).reload.video_timeout_minutes
    end
  end
end

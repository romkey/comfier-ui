require 'test_helper'

module Admin
  class AssistantSettingsTest < ActionDispatch::IntegrationTest
    test 'non-admins cannot edit workflow assistant settings' do
      sign_in_as users(:alice)

      get edit_admin_assistant_setting_path

      assert_response :not_found
    end

    test 'admins can view and update the placeholder prompt' do
      sign_in_as users(:admin)

      get edit_admin_assistant_setting_path

      assert_response :success
      assert_select 'h1', text: 'Workflow assistant'
      assert_select 'textarea[name="app_setting[placeholder_prompt]"]'

      patch admin_assistant_setting_path, params: { app_setting: { placeholder_prompt: 'Custom rules.' } }

      assert_redirected_to edit_admin_assistant_setting_path
      assert_equal 'Custom rules.', app_settings(:default).reload.placeholder_prompt
    end

    test 'admins can reset the prompt to the built-in default' do
      sign_in_as users(:admin)
      app_settings(:default).update!(placeholder_prompt: 'Custom rules.')

      patch admin_assistant_setting_path, params: { reset_prompt: '1', app_setting: { placeholder_prompt: 'ignored' } }

      assert_redirected_to edit_admin_assistant_setting_path
      assert_nil app_settings(:default).reload.placeholder_prompt
    end
  end
end

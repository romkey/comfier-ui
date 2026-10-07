require 'test_helper'

module Admin
  class ChatSettingsTest < ActionDispatch::IntegrationTest
    setup do
      @previous = {
        'LITELLM_URL' => ENV.fetch('LITELLM_URL', nil),
        'LITELLM_MODEL' => ENV.fetch('LITELLM_MODEL', nil)
      }
      ENV['LITELLM_URL'] = 'http://litellm.test'
      ENV['LITELLM_MODEL'] = 'gpt-test'
      stub_request(:get, 'http://litellm.test/v1/models')
        .to_return(body: { data: [{ id: 'gpt-test' }] }.to_json)
    end

    teardown do
      @previous.each { |key, value| ENV[key] = value }
    end

    test 'non-admins cannot edit chat settings' do
      sign_in_as users(:alice)

      get edit_admin_chat_setting_path

      assert_response :not_found
    end

    test 'admins can update chat settings' do
      sign_in_as users(:admin)

      get edit_admin_chat_setting_path

      assert_response :success
      assert_select 'h1', text: 'Chat'

      patch admin_chat_setting_path, params: {
        app_setting: {
          chat_default_model: 'gpt-test',
          chat_notice_text: 'Try the full assistant',
          chat_notice_url: 'https://chat.example.com'
        }
      }

      assert_redirected_to edit_admin_chat_setting_path
      settings = app_settings(:default).reload

      assert_equal 'gpt-test', settings.chat_default_model
      assert_equal 'Try the full assistant', settings.chat_notice_text
      assert_equal 'https://chat.example.com', settings.chat_notice_url
    end

    test 'admins can edit and reset the video script prompt' do
      sign_in_as users(:admin)

      get edit_admin_chat_setting_path

      assert_select 'textarea[name="app_setting[video_script_prompt]"]', text: AppSetting.default_video_script_prompt

      patch admin_chat_setting_path, params: { app_setting: { video_script_prompt: 'Script for {{prompt}}' } }

      assert_equal 'Script for {{prompt}}', app_settings(:default).reload.video_script_prompt

      patch admin_chat_setting_path,
            params: { reset_video_script_prompt: '1', app_setting: { video_script_prompt: 'ignored' } }

      assert_nil app_settings(:default).reload.video_script_prompt
    end

    test 'saving the unchanged default keeps following the built-in prompt' do
      sign_in_as users(:admin)

      patch admin_chat_setting_path,
            params: { app_setting: { video_script_prompt: AppSetting.default_video_script_prompt.gsub("\n", "\r\n") } }

      assert_predicate app_settings(:default).reload, :using_default_video_script_prompt?
    end
  end
end

require 'test_helper'

module Admin
  class AlbumArtSettingsTest < ActionDispatch::IntegrationTest
    test 'non-admins cannot edit album art settings' do
      sign_in_as users(:alice)

      get edit_admin_album_art_setting_path

      assert_response :not_found
    end

    test 'admins pick the image style from styles that work from a prompt' do
      sign_in_as users(:admin)

      get edit_admin_album_art_setting_path

      assert_response :success
      assert_select 'h1', text: 'Album art'
      assert_select 'select[name="app_setting[album_art_workflow_id]"]' do
        assert_select 'option', text: 'First available (SD 1.5)'
        assert_select "option[value='#{workflows(:sdxl_image).id}']"
        assert_select "option[value='#{workflows(:retired_image).id}']", count: 0
      end

      patch admin_album_art_setting_path, params: { app_setting: { album_art_workflow_id: workflows(:sdxl_image).id } }

      assert_redirected_to edit_admin_album_art_setting_path
      assert_equal workflows(:sdxl_image), app_settings(:default).reload.album_art_workflow
    end

    test 'rejects a style that cannot make album art' do
      sign_in_as users(:admin)

      patch admin_album_art_setting_path, params: { app_setting: { album_art_workflow_id: workflows(:wan_video).id } }

      assert_response :unprocessable_content
      assert_nil app_settings(:default).reload.album_art_workflow_id
    end

    test 'admins can edit and reset the prompt' do
      sign_in_as users(:admin)

      get edit_admin_album_art_setting_path

      assert_select 'textarea[name="app_setting[album_art_prompt]"]', text: AppSetting.default_album_art_prompt

      patch admin_album_art_setting_path, params: { app_setting: { album_art_prompt: "Cover for {{prompt}}\r\n" } }

      assert_equal 'Cover for {{prompt}}', app_settings(:default).reload.album_art_prompt

      patch admin_album_art_setting_path, params: { app_setting: { album_art_prompt: 'ignored' },
                                                    reset_album_art_prompt: '1' }

      assert_predicate app_settings(:default).reload, :using_default_album_art_prompt?

      patch admin_album_art_setting_path,
            params: { app_setting: { album_art_prompt: AppSetting.default_album_art_prompt } }

      assert_predicate app_settings(:default).reload, :using_default_album_art_prompt?
    end
  end
end

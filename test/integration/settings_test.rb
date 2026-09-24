require 'test_helper'

class SettingsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:alice)
  end

  test 'shows preferences without admin sections' do
    get settings_path

    assert_response :success
    assert_select 'h1', text: 'Your preferences'
    assert_select '.settings-nav', text: /Backends/, count: 0
  end

  test 'saves preferences' do
    patch settings_path, params: { user: { default_aspect_ratio: '3:4', default_negative_prompt: 'text' } }

    assert_redirected_to settings_path
    assert_equal '3:4', users(:alice).reload.default_aspect_ratio
    assert_equal 'text', users(:alice).default_negative_prompt
  end

  test 'rejects an unsupported aspect ratio' do
    patch settings_path, params: { user: { default_aspect_ratio: '7:1' } }

    assert_response :unprocessable_content
    assert_equal '1:1', users(:alice).reload.default_aspect_ratio
  end

  test 'offers a server choice only when there is one to make' do
    get settings_path

    assert_select 'select[name="user[preferred_backend_id]"]', count: 0

    Backend.create!(name: 'Second', base_url: 'http://second.test')
    get settings_path

    assert_select 'select[name="user[preferred_backend_id]"] option', text: 'Automatic (least busy)'
  end

  test 'cannot prefer a disabled backend' do
    patch settings_path, params: { user: { preferred_backend_id: backends(:offline).id } }

    assert_response :unprocessable_content
    assert_nil users(:alice).reload.preferred_backend
  end

  test 'admins see what needs attention' do
    sign_in_as users(:admin)
    get settings_path

    assert_select '.settings-nav', text: /Backends/
    assert_select '.settings-nav-item.attention', text: /No audio workflow/
  end

  test 'attention items keep the 3D capitalization' do
    workflows(:image_to_3d).update!(enabled: false)
    sign_in_as users(:admin)
    get settings_path

    assert_select '.settings-nav-item.attention', text: /No 3D model workflow/
  end
end

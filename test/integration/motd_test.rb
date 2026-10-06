require 'test_helper'

class MotdTest < ActionDispatch::IntegrationTest
  setup do
    @settings = AppSetting.current
  end

  test 'no banner when there is no message' do
    sign_in_as users(:alice)
    get settings_path

    assert_select '#motd', count: 0
  end

  test 'signed-in users see the message at the top of every page' do
    @settings.update!(motd_text: 'Maintenance tonight at 9pm')
    sign_in_as users(:alice)

    [settings_path, generations_path, queue_path].each do |path|
      get path

      assert_select 'body > #motd', text: /Maintenance tonight at 9pm/
    end
  end

  test 'dismissing hides the message until it changes' do
    @settings.update!(motd_text: 'First message')
    alice = users(:alice)
    sign_in_as alice

    post motd_dismissal_path, params: { digest: @settings.motd_digest }, as: :turbo_stream

    assert_response :success
    assert_match '<turbo-stream action="remove" target="motd">', response.body
    assert_equal @settings.motd_digest, alice.reload.dismissed_motd_digest

    get settings_path

    assert_select '#motd', count: 0

    @settings.update!(motd_text: 'Second message')
    get settings_path

    assert_select '#motd', text: /Second message/
  end

  test 'dismissing without turbo redirects back' do
    @settings.update!(motd_text: 'Hello')
    sign_in_as users(:alice)

    post motd_dismissal_path, params: { digest: @settings.motd_digest }, headers: { 'HTTP_REFERER' => queue_url }

    assert_redirected_to queue_url
  end

  test 'one user dismissing does not hide it for others' do
    @settings.update!(motd_text: 'Hello everyone')
    sign_in_as users(:alice)
    post motd_dismissal_path, params: { digest: @settings.motd_digest }, as: :turbo_stream

    sign_in_as users(:bob)
    get settings_path

    assert_select '#motd', text: /Hello everyone/
  end

  test 'the message is escaped' do
    @settings.update!(motd_text: '<script>alert(1)</script>')
    sign_in_as users(:alice)
    get settings_path

    assert_select '#motd script', count: 0
    assert_select '#motd', text: %r{<script>alert\(1\)</script>}
  end

  test 'admins set and clear the message' do
    sign_in_as users(:admin)

    get edit_admin_motd_path

    assert_response :success
    assert_select 'h1', text: 'Message of the day'

    patch admin_motd_path, params: { app_setting: { motd_text: '  Welcome back  ' } }

    assert_redirected_to edit_admin_motd_path
    assert_equal 'Welcome back', @settings.reload.motd_text

    patch admin_motd_path, params: { app_setting: { motd_text: '' } }

    assert_nil @settings.reload.motd_text
    assert_not_predicate @settings, :motd?
  end

  test 'admins cannot save an overly long message' do
    sign_in_as users(:admin)
    patch admin_motd_path, params: { app_setting: { motd_text: 'x' * 1001 } }

    assert_response :unprocessable_content
    assert_nil @settings.reload.motd_text
  end

  test 'non-admins cannot edit the message' do
    sign_in_as users(:alice)

    get edit_admin_motd_path

    assert_response :not_found

    patch admin_motd_path, params: { app_setting: { motd_text: 'Hijacked' } }

    assert_response :not_found
    assert_nil @settings.reload.motd_text
  end
end

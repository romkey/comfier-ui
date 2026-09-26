require 'test_helper'

class OnboardingTest < ActionDispatch::IntegrationTest
  test 'privacy acceptance sends new users to the sharing choice' do
    user = User.create!(
      provider: 'authentik', uid: 'new-user', email: 'new@example.com', name: 'New User',
      default_aspect_ratio: '1:1', privacy_accepted_version: nil
    )
    sign_in_as user

    post accept_privacy_path

    assert_redirected_to welcome_sharing_path
    assert_equal PrivacyNotice.current.version, user.reload.privacy_accepted_version
  end

  test 'choosing a default sharing preference saves it and continues' do
    user = users(:alice)
    user.update_columns(privacy_accepted_version: PrivacyNotice.current.version, share_by_default: nil) # rubocop:disable Rails/SkipsModelValidations
    sign_in_as user

    patch welcome_sharing_path, params: { share_by_default: '1' }

    assert_redirected_to root_path
    assert_predicate user.reload, :share_by_default?
  end

  test 'users who already chose a default skip the onboarding screen' do
    sign_in_as users(:alice)

    get welcome_sharing_path

    assert_redirected_to root_path
  end

  test 'the studio form pre-checks share when the user defaults to sharing' do
    users(:alice).update!(share_by_default: true)
    sign_in_as users(:alice)

    get image_studio_path

    assert_response :success
    assert_select 'input[name="generation[share_result]"][checked=checked]'
  end
end

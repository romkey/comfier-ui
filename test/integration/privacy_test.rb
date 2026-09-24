require 'test_helper'

class PrivacyTest < ActionDispatch::IntegrationTest
  test 'users who have not agreed are sent to the privacy page' do
    users(:alice).update!(privacy_accepted_version: nil, privacy_accepted_at: nil)
    sign_in_as users(:alice)

    get image_studio_path

    assert_redirected_to privacy_path
  end

  test 'agreeing records the version and sends the user on their way' do
    users(:alice).update!(privacy_accepted_version: nil)
    sign_in_as users(:alice)
    get image_studio_path

    post accept_privacy_path

    assert_redirected_to image_studio_path
    assert_predicate users(:alice).reload, :privacy_current?
  end

  test 'admins can edit the notice and bump the version' do
    sign_in_as users(:admin)

    patch admin_privacy_notice_path, params: { privacy_notice: { body: 'Updated wording.' }, require_reacceptance: '1' }

    assert_redirected_to edit_admin_privacy_notice_path
    assert_equal 2, PrivacyNotice.current.version
    assert_match(/Updated wording/, PrivacyNotice.current.body)
  end

  test 'a bumped version sends users back to agree again' do
    sign_in_as users(:admin)
    patch admin_privacy_notice_path, params: { privacy_notice: { body: PrivacyNotice.current.body },
                                               require_reacceptance: '1' }
    sign_in_as users(:alice)

    get generations_path

    assert_redirected_to privacy_path
  end
end

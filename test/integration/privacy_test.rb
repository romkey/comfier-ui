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

  test 'the notice links to the code of conduct and offers both choices' do
    users(:alice).update!(privacy_accepted_version: nil)
    sign_in_as users(:alice)

    get privacy_path

    assert_select 'a[href=?]', 'https://example.com/code-of-conduct.pdf'
    assert_select 'button', 'I Understand and Agree'
    assert_select 'button', 'I Do Not Agree'
  end

  test 'declining signs the user out and sends them to the decline page' do
    users(:alice).update!(privacy_accepted_version: nil)
    sign_in_as users(:alice)

    post decline_privacy_path

    assert_redirected_to 'https://example.com/goodbye'
    get image_studio_path

    assert_redirected_to login_path
    assert_nil users(:alice).reload.privacy_accepted_version
  end

  test 'admins can change the code of conduct and decline links' do
    sign_in_as users(:admin)

    patch admin_privacy_notice_path, params: { privacy_notice: { body: 'Be kind.',
                                                                 code_of_conduct_url: 'https://example.org/coc',
                                                                 decline_url: 'https://example.org/bye' } }

    notice = PrivacyNotice.current

    assert_equal 'https://example.org/coc', notice.code_of_conduct_url
    assert_equal 'https://example.org/bye', notice.decline_url
    assert_equal 1, notice.version
  end

  test 'admins cannot save a link that is not a web address' do
    sign_in_as users(:admin)

    patch admin_privacy_notice_path, params: { privacy_notice: { body: 'Be kind.',
                                                                 decline_url: 'javascript:alert(1)' } }

    assert_response :unprocessable_content
    assert_equal 'https://example.com/goodbye', PrivacyNotice.current.decline_url
  end
end

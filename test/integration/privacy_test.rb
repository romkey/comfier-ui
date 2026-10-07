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

    assert_select 'a[href=?]', code_of_conduct_path
    assert_select 'button', 'I Understand and Agree'
    assert_select 'button', 'I Do Not Agree'
  end

  test 'the code of conduct link goes to the admin-chosen document' do
    sign_in_as users(:alice)

    get code_of_conduct_path

    assert_redirected_to 'https://example.com/code-of-conduct.pdf'
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

  test 'agreeing from a page kept after declining shows the notice again instead of a 422' do
    users(:alice).update!(privacy_accepted_version: nil)
    sign_in_as users(:alice)

    with_forgery_protection do
      get privacy_path
      stale_token = css_select("form[action='#{accept_privacy_path}'] input[name=authenticity_token]").first['value']
      decline_token = css_select("form[action='#{decline_privacy_path}'] input[name=authenticity_token]").first['value']
      post decline_privacy_path, params: { authenticity_token: decline_token }

      post accept_privacy_path, params: { authenticity_token: stale_token }

      assert_redirected_to privacy_path
    end
    assert_nil users(:alice).reload.privacy_accepted_version
  end

  test 'the notice page is not kept for the back button' do
    users(:alice).update!(privacy_accepted_version: nil)
    sign_in_as users(:alice)

    get privacy_path

    assert_equal 'no-store', response.headers['Cache-Control']
  end

  private

  def with_forgery_protection
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end

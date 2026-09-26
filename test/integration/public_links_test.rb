require 'test_helper'

class PublicLinksTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:alice) }

  test 'lists only the current user public links' do
    mine = generations(:alice_done)
    mine.update!(status: :succeeded)
    mine.create_public_link!
    other = generations(:bob_done)
    other.update!(status: :succeeded)
    other.create_public_link!

    get public_links_path

    assert_response :success
    assert_select 'td', text: /lighthouse/i
    assert_select 'td', text: /Bob's secret project/, count: 0
  end

  test 'revoke all clears every public link for the user' do
    generations(:alice_done).update!(status: :succeeded)
    generations(:alice_done).create_public_link!
    generations(:alice_failed).update!(status: :succeeded, public_token: 'keep-me', public_shared_at: Time.current)

    delete public_links_path

    assert_redirected_to public_links_path
    assert_not generations(:alice_done).reload.publicly_linked?
    assert_not generations(:alice_failed).reload.publicly_linked?
  end
end

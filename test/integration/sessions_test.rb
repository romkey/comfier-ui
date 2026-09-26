require 'test_helper'

class SessionsTest < ActionDispatch::IntegrationTest
  test 'pages require signing in' do
    %w[/image /video /audio /3d /results /settings /admin/backends].each do |path|
      get path

      assert_redirected_to login_path, "#{path} should require sign-in"
    end
  end

  test 'the root goes to the Image page' do
    get '/'

    assert_redirected_to '/image'
  end

  test 'the login page offers Authentik' do
    get login_path

    assert_response :success
    assert_select 'form[action="/auth/authentik"] button', text: /Sign in with Authentik/
  end

  test 'signing in creates the user and returns to the page they wanted' do
    get '/results'
    OmniAuth.config.mock_auth[:authentik] = auth_hash(uid: 'fresh', email: 'fresh@example.com', name: 'Fresh Face')

    assert_difference('User.count', 1) { get '/auth/authentik/callback' }
    follow_redirect!
    post accept_privacy_path

    assert_redirected_to welcome_sharing_path
    follow_redirect!
    patch welcome_sharing_path, params: { share_by_default: '0' }

    assert_redirected_to '/results'
    follow_redirect!

    assert_response :success
    assert_select '.navbar', text: /Fresh Face/
  end

  test 'signing in without a saved page goes home' do
    OmniAuth.config.mock_auth[:authentik] = auth_hash(uid: users(:alice).uid)
    get '/auth/authentik/callback'

    assert_redirected_to root_path
  end

  test 'a callback for a provider that is not configured goes back to the login page' do
    assert_no_difference('User.count') do
      get '/auth/developer/callback', params: { name: 'dev@example.com', email: 'dev@example.com' }
    end

    assert_redirected_to login_path
    assert_match(/sign in again/, flash[:alert])
  end

  test 'a failed sign-in explains itself' do
    get '/auth/failure', params: { message: 'invalid_credentials' }

    assert_redirected_to login_path
    assert_equal 'Sign-in failed: Invalid credentials', flash[:alert]
  end

  test 'signing out ends the session' do
    sign_in_as users(:alice)

    delete logout_path

    assert_redirected_to login_path
    get '/image'

    assert_redirected_to login_path
  end

  test 'signed-in users skip the login page' do
    sign_in_as users(:alice)
    get login_path

    assert_redirected_to root_path
  end

  test 'the navbar has every section' do
    sign_in_as users(:alice)
    get '/image'

    assert_select '.navbar-nav .nav-link', minimum: 8
    assert_select '.navbar-nav .nav-link.active', text: 'Image'
    %w[Image Video Audio Results Shared Queue Settings].each do |label|
      assert_select '.navbar-nav .nav-link', text: /#{label}/
    end
  end
end

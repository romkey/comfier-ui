require 'test_helper'

class DevSessionsTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.config.x.dev_login = { email: 'dev@example.com', password: 'hunter2', name: 'Dev', admin: true }
  end

  teardown do
    Rails.application.config.x.dev_login = nil
  end

  test 'the login page shows the developer form when configured' do
    get login_path

    assert_select 'form[action="/dev_login"] input[type=password]'
  end

  test 'the right credentials sign in and return to the page wanted' do
    get '/results'
    post dev_login_path, params: { email: 'dev@example.com', password: 'hunter2' }

    assert_redirected_to '/results'
    follow_redirect!

    assert_select '.navbar', text: /Dev/
  end

  test 'wrong credentials are refused' do
    assert_no_difference('User.count') do
      post dev_login_path, params: { email: 'dev@example.com', password: 'nope' }
    end

    assert_redirected_to login_path
    get '/image'

    assert_redirected_to login_path
  end

  test 'is not routable when developer sign-in is off' do
    Rails.application.config.x.dev_login = nil
    post dev_login_path, params: { email: 'dev@example.com', password: 'hunter2' }

    assert_response :not_found
    get login_path

    assert_select 'form[action="/dev_login"]', count: 0
  end

  test 'explains missing credentials instead of showing the form' do
    Rails.application.config.x.dev_login = { email: '', password: '', name: 'Developer', admin: true }
    get login_path

    assert_select 'form[action="/dev_login"]', count: 0
    assert_select '.alert', text: /DEV_LOGIN_PASSWORD/
    post dev_login_path, params: { email: '', password: '' }

    assert_response :not_found
  end
end

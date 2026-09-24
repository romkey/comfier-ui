require 'test_helper'

class DevLoginTest < ActiveSupport::TestCase
  setup do
    Rails.application.config.x.dev_login = { email: 'dev@example.com', password: 'hunter2', name: 'Dev', admin: true }
  end

  teardown do
    Rails.application.config.x.dev_login = nil
  end

  test 'is off outside development unless configured' do
    Rails.application.config.x.dev_login = nil

    assert_not DevLogin.requested?
    assert_not DevLogin.enabled?
    assert_not DevLogin.authenticate('dev@example.com', 'hunter2')
  end

  test 'stays off until both an email and a password are set' do
    Rails.application.config.x.dev_login = { email: 'dev@example.com', password: '', name: 'Dev', admin: true }

    assert_predicate DevLogin, :requested?
    assert_not DevLogin.enabled?
    assert_not DevLogin.authenticate('dev@example.com', '')
  end

  test 'accepts the configured credentials, ignoring email case and spacing' do
    assert DevLogin.authenticate(' Dev@Example.com ', 'hunter2')
  end

  test 'rejects a wrong email or password' do
    assert_not DevLogin.authenticate('dev@example.com', 'hunter3')
    assert_not DevLogin.authenticate('other@example.com', 'hunter2')
    assert_not DevLogin.authenticate(nil, nil)
  end

  test 'creates the account from the config and keeps it in sync' do
    user = assert_difference('User.count', 1) { DevLogin.user }

    assert_equal ['developer', 'dev@example.com', 'Dev'], [user.provider, user.uid, user.name]
    assert_predicate user, :admin?

    Rails.application.config.x.dev_login = DevLogin.config.merge(name: 'Renamed', admin: false)

    assert_no_difference('User.count') { DevLogin.user }
    assert_equal 'Renamed', user.reload.name
    assert_not user.admin?
  end
end

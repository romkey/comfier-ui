require 'test_helper'

class UserTest < ActiveSupport::TestCase
  test 'from_omniauth creates a user from the Authentik claims' do
    auth = auth_hash(uid: 'new-uid', email: 'new@example.com', name: 'New Person')

    user = assert_difference('User.count', 1) { User.from_omniauth(auth) }

    assert_equal 'authentik', user.provider
    assert_equal 'new@example.com', user.email
    assert_equal 'New Person', user.name
    assert_equal 'new', user.username
    assert_not user.admin?
    assert_not_nil user.last_signed_in_at
  end

  test 'from_omniauth updates an existing user instead of duplicating' do
    auth = auth_hash(uid: users(:alice).uid, email: 'alice@new.example.com', name: 'Alice Renamed')

    assert_no_difference('User.count') { User.from_omniauth(auth) }
    assert_equal 'alice@new.example.com', users(:alice).reload.email
    assert_equal 'Alice Renamed', users(:alice).name
  end

  test 'from_omniauth links Slack from the slack claim' do
    user = User.from_omniauth(auth_hash(uid: users(:alice).uid, slack: { 'uid' => 'U123', 'name' => 'alice.a' }))

    assert_equal 'U123', user.slack_uid
    assert_equal 'alice.a', user.slack_name
  end

  test 'from_omniauth clears the Slack link when the claim goes away' do
    users(:alice).update!(slack_uid: 'U123', slack_name: 'alice.a')
    user = User.from_omniauth(auth_hash(uid: users(:alice).uid))

    assert_nil user.slack_uid
    assert_nil user.slack_name
  end

  test 'notification channels need a preference, an address and server configuration' do
    user = users(:alice)
    user.assign_attributes(notify_email: true, notify_slack: true)

    with_env('SMTP_ADDRESS' => nil, 'SLACK_BOT_TOKEN' => nil) do
      assert_not user.notify_via_email?
      assert_not user.notify_via_slack?
    end

    with_notifications_configured do
      assert_predicate user, :notify_via_email?
      assert_not user.notify_via_slack?

      user.slack_uid = 'U123'

      assert_predicate user, :notify_via_slack?

      user.notify_email = false

      assert_not user.notify_via_email?
    end
  end

  test 'admin rights follow membership of the Authentik admin group' do
    promoted = User.from_omniauth(auth_hash(uid: users(:alice).uid, groups: ['staff', User.admin_group]))

    assert_predicate promoted, :admin?

    demoted = User.from_omniauth(auth_hash(uid: users(:admin).uid, groups: ['staff']))

    assert_not demoted.admin?
  end

  test 'the admin group name can be configured' do
    ENV['AUTHENTIK_ADMIN_GROUP'] = 'wizards'
    user = User.from_omniauth(auth_hash(uid: 'wizard', groups: ['wizards']))

    assert_predicate user, :admin?
  ensure
    ENV.delete('AUTHENTIK_ADMIN_GROUP')
  end

  test 'display_name falls back from name to username to email' do
    user = User.new(email: 'x@example.com')

    assert_equal 'x@example.com', user.display_name
    user.username = 'xavier'

    assert_equal 'xavier', user.display_name
    user.name = 'Xavier X'

    assert_equal 'Xavier X', user.display_name
    assert_equal 'XX', user.initials
  end

  test 'default aspect ratio must be one we support' do
    user = users(:alice)
    user.default_aspect_ratio = '2:1'

    assert_not user.valid?
  end

  test 'preferred backend must be enabled' do
    user = users(:alice)
    user.preferred_backend = backends(:offline)

    assert_not user.valid?
    user.preferred_backend = backends(:gpu)

    assert_predicate user, :valid?
  end
end

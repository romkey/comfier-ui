require 'test_helper'

class PersonalApiTokenTest < ActiveSupport::TestCase
  test 'issues a unique secret and stores only its digest and display prefix' do
    token, secret = PersonalApiToken.issue!(user: users(:alice), name: 'My script')
    other, other_secret = PersonalApiToken.issue!(user: users(:alice), name: 'My script')

    assert_match PersonalApiToken::TOKEN_PATTERN, secret
    assert_equal Digest::SHA256.hexdigest(secret), token.token_digest
    assert_equal secret.first(13), token.token_prefix
    assert_equal token, PersonalApiToken.authenticate(secret)
    assert_equal users(:alice), token.user
    assert_not_equal secret, other_secret
    assert_not_equal token.token_digest, other.token_digest
  end

  test 'revoked tokens stop authenticating' do
    token, secret = PersonalApiToken.issue!(user: users(:alice), name: 'My script')
    token.revoke!
    revoked_at = token.revoked_at
    token.revoke!

    assert_nil PersonalApiToken.authenticate(secret)
    assert_equal revoked_at, token.revoked_at
  end

  test 'rejects malformed secrets and server agent keys' do
    [nil, '', 'cmf_12345', "cmfu_#{'a' * 64}", 'cmfu_short', 123].each do |secret|
      assert_nil PersonalApiToken.authenticate(secret)
    end
  end

  test 'requires a short descriptive name' do
    assert_raises(ActiveRecord::RecordInvalid) { PersonalApiToken.issue!(user: users(:alice), name: '') }
    assert_raises(ActiveRecord::RecordInvalid) do
      PersonalApiToken.issue!(user: users(:alice), name: 'x' * 101)
    end
  end

  test 'deleting a user deletes their tokens' do
    user = User.create!(provider: 'authentik', uid: 'token-deletion-test')
    token, = PersonalApiToken.issue!(user:, name: 'My script')
    user.destroy!

    assert_not PersonalApiToken.exists?(token.id)
  end
end

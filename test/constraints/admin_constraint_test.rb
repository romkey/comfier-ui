require 'test_helper'

class AdminConstraintTest < ActiveSupport::TestCase
  def request_with(session) = Struct.new(:session).new(session)

  test 'matches only signed-in admins' do
    assert AdminConstraint.matches?(request_with(user_id: users(:admin).id))
    assert_not AdminConstraint.matches?(request_with(user_id: users(:alice).id))
    assert_not AdminConstraint.matches?(request_with({}))
  end
end

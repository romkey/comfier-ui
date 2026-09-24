require 'test_helper'

# Tests use Action Cable's test adapter, so a gem conflict in the Redis adapter used by dev and
# production (which broadcasts live generation updates) would otherwise go unnoticed.
class ActionCableTest < ActiveSupport::TestCase
  test 'the Redis subscription adapter loads with the bundled redis gem' do
    assert_nothing_raised { require 'action_cable/subscription_adapter/redis' }
  end

  test 'dev and production broadcast through Redis' do
    config = ActiveSupport::ConfigurationFile.parse(Rails.root.join('config/cable.yml'))

    assert_equal 'redis', config.dig('development', 'adapter')
    assert_equal 'redis', config.dig('production', 'adapter')
  end
end

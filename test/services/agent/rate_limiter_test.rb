# frozen_string_literal: true

require 'test_helper'

module Agent
  class RateLimiterTest < ActiveSupport::TestCase
    test 'allows up to the limit within a second' do
      limiter = WebsocketApp::RateLimiter.new(limit: 3)

      assert_equal [true, true, true, false], Array.new(4) { limiter.allowed? }
    end

    # Under load each message can take longer to handle than the window; a burst still counts as one.
    test 'a burst trips the limit even when each message is slow to handle' do
      limiter = WebsocketApp::RateLimiter.new(limit: 3)
      results = Array.new(4) { limiter.allowed?.tap { limiter.handling { sleep 0.4 } } }

      assert_equal [true, true, true, false], results
    end

    test 'time between messages still counts' do
      limiter = WebsocketApp::RateLimiter.new(limit: 1)

      assert_predicate limiter, :allowed?
      sleep 1.05

      assert_predicate limiter, :allowed?
    end
  end
end

# frozen_string_literal: true

require 'test_helper'

module Agent
  class RateLimiterTest < ActiveSupport::TestCase
    test 'allows up to the limit within a second' do
      limiter = WebsocketApp::RateLimiter.new(rate: 3, burst: 3)

      assert_equal [true, true, true, false], Array.new(4) { limiter.allowed? }
    end

    # Under load each message can take longer to handle than the window; a burst still counts as one.
    test 'a burst trips the limit even when each message is slow to handle' do
      limiter = WebsocketApp::RateLimiter.new(rate: 3, burst: 3)
      results = Array.new(4) { limiter.allowed?.tap { limiter.handling { sleep 0.4 } } }

      assert_equal [true, true, true, false], results
    end

    # A reconnect sends hello, inventory, status and its buffered results at once.
    test 'a burst above the rate is allowed up to the burst size' do
      limiter = WebsocketApp::RateLimiter.new(rate: 2, burst: 5)

      assert_equal(([true] * 5) + [false], Array.new(6) { limiter.allowed? })
    end

    test 'a legal reconnect fits the default burst' do
      limiter = WebsocketApp::RateLimiter.new
      reconnect = 1 + 1 + 5 + 1 + 50 + 10 # hello, inventory, object_info chunks, status, job and download results

      assert_predicate Array.new(reconnect) { limiter.allowed? }, :all?
    end

    test 'time between messages still counts' do
      limiter = WebsocketApp::RateLimiter.new(rate: 1, burst: 1)

      assert_predicate limiter, :allowed?
      sleep 1.05

      assert_predicate limiter, :allowed?
    end
  end
end

# frozen_string_literal: true

require 'test_helper'

class QueueHelperTest < ActionView::TestCase
  include QueueHelper

  test 'wait label does not double up the hedge' do
    assert_equal 'about 1 hour', queue_wait_label(60 * 60)
    assert_equal 'about 10 minutes', queue_wait_label(10 * 60)
    assert_equal 'less than a minute', queue_wait_label(20)
    assert_equal 'now', queue_wait_label(3)
  end
end

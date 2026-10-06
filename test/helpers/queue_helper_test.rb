# frozen_string_literal: true

require 'test_helper'

class QueueHelperTest < ActionView::TestCase
  include QueueHelper
  include AgentProgressHelper

  attr_accessor :current_user

  test 'wait label does not double up the hedge' do
    assert_equal 'about 1 hour', queue_wait_label(60 * 60)
    assert_equal 'about 10 minutes', queue_wait_label(10 * 60)
    assert_equal 'less than a minute', queue_wait_label(20)
    assert_equal 'now', queue_wait_label(3)
  end

  test "a job parked for its owner's server reads right for other viewers" do
    gen = Generation.create!(user: users(:alice), workflow: workflows(:sd_image), prompt: 'x', kind: :image,
                             status: :queued, agent_state: 'routing', agent_phase: 'waiting_for_server',
                             filled_workflow_json: {})

    self.current_user = users(:alice)

    assert_equal Agent::Router::WAITING_FOR_OWN, queue_wait_reason(gen)

    self.current_user = users(:bob)

    assert_equal "Waiting for the owner's server to come online", queue_wait_reason(gen)
  end
end

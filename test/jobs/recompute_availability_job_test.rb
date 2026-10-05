# frozen_string_literal: true

require 'test_helper'

class RecomputeAvailabilityJobTest < ActiveJob::TestCase
  setup do
    @alice = users(:alice)
    @workflow = workflows(:sd_image)
    @backend = create_agent_backend!(owner: @alice)
    bring_online_for!(@backend, @workflow)
  end

  test 'recomputing one server refreshes its styles frame' do
    assert_enqueued_jobs(1, only: Turbo::Streams::BroadcastStreamJob) do
      RecomputeAvailabilityJob.perform_now(backend_id: @backend.id)
    end
  end

  test 'recomputing a workflow refreshes styles on every agent server' do
    other = create_agent_backend!(owner: @alice, name: 'Other')
    bring_online_for!(other, @workflow)

    assert_enqueued_jobs(2, only: Turbo::Streams::BroadcastStreamJob) do
      RecomputeAvailabilityJob.perform_now(workflow_id: @workflow.id)
    end
  end
end

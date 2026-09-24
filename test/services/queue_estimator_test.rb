require 'test_helper'

class QueueEstimatorTest < ActiveSupport::TestCase
  test 'an empty queue clears immediately' do
    Generation.in_progress.find_each { it.update!(status: :succeeded, completed_at: Time.current) }

    result = QueueEstimator.call

    assert_equal 0, result[:count]
    assert_equal 0, result[:total_clear_seconds]
  end

  test 'a running job gets a remaining time' do
    job = generations(:alice_running)
    job.update!(submitted_at: 10.seconds.ago)

    estimate = QueueEstimator.call[:jobs].find { it.generation.id == job.id }

    assert_predicate estimate.remaining_seconds, :positive?
    assert_equal 1, estimate.position
  end

  test 'history on the workflow improves the estimate' do
    workflow = workflows(:sd_image)
    5.times do
      Generation.create!(user: users(:alice), workflow:, kind: 'image', status: :succeeded, prompt: 'x',
                         parameters: { frames: 1, batch_size: 1, quality: 'standard' }, run_seconds: 40,
                         workflow_name: workflow.name, completed_at: Time.current)
    end
    job = Generation.create!(user: users(:bob), workflow:, kind: 'image', status: :queued, prompt: 'y',
                             parameters: { frames: 1, batch_size: 1, quality: 'standard' },
                             workflow_name: workflow.name)

    seconds = QueueEstimator.new.estimate_seconds(job)

    assert_in_delta 40, seconds, 5
    job.destroy!
  end

  test 'unassigned jobs pick the soonest backend' do
    Generation.in_progress.find_each { it.update!(status: :queued, backend: nil, submitted_at: Time.current) }
    backends(:gpu).update!(enabled: true)

    result = QueueEstimator.call

    assert(result[:jobs].all? { it.backend.present? })
  end
end

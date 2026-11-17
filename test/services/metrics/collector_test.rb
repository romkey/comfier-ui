require 'test_helper'

module Metrics
  class CollectorTest < ActiveSupport::TestCase
    # Sidekiq's numbers come from Redis, which the test suite doesn't run.
    class FakeJobQueue < Sections::JobQueue
      Stats = Struct.new(:processed, :failed, :enqueued, :scheduled_size, :retry_size, :dead_size, :workers_size,
                         :processes_size)
      Queue = Data.define(:name, :size, :latency)

      private

      def stats = Stats.new(120, 4, 7, 2, 1, 0, 3, 1)
      def queue_list = [Queue.new(name: 'default', size: 7, latency: 12.5)]
    end

    class Broken < Sections::Base
      def collect = raise('boom')
    end

    def render(sections = Collector::SECTIONS.merge('sidekiq' => FakeJobQueue))
      Collector.render(sections:)
    end

    # The value of the sample with exactly this name and these labels, or nil.
    def value(text, name, labels = {})
      rendered = labels.map { |key, val| %(#{key}="#{val}") }.join(',')
      series = rendered.empty? ? name : "#{name}{#{rendered}}"
      line = text.each_line(chomp: true).find { it.start_with?("#{series} ") }
      line && line.split.last.to_f
    end

    test 'every section collects without error' do
      text = render

      Collector::SECTIONS.each_key do |section|
        assert_equal 0, value(text, 'comfier_scrape_section_errors', section:), section
      end
      assert_operator value(text, 'comfier_scrape_duration_seconds'), :>=, 0
      assert_includes text, %(comfier_build_info{version="#{AppVersion.semver}")
    end

    test 'a failing section is flagged and the others still report' do
      text = render('users' => Sections::Users, 'broken' => Broken)

      assert_equal 1, value(text, 'comfier_scrape_section_errors', section: 'broken')
      assert_equal 0, value(text, 'comfier_scrape_section_errors', section: 'users')
      assert_equal 1, value(text, 'comfier_users', role: 'admin')
    end

    test 'users are counted by role and by recent activity' do
      users(:alice).update!(last_signed_in_at: 2.days.ago)
      users(:bob).update!(last_signed_in_at: 20.days.ago)
      users(:alice).personal_api_tokens.create!(name: 'ci', token_digest: 'd', token_prefix: 'p',
                                                last_used_at: 1.hour.ago)
      text = render

      assert_equal 1, value(text, 'comfier_users', role: 'admin')
      assert_equal User.count - 1, value(text, 'comfier_users', role: 'user')
      assert_equal 0, value(text, 'comfier_users_signed_in', window: '1d')
      assert_equal 1, value(text, 'comfier_users_signed_in', window: '7d')
      assert_equal 2, value(text, 'comfier_users_signed_in', window: '30d')
      assert_equal Generation.where(created_at: 1.day.ago..).distinct.count(:user_id),
                   value(text, 'comfier_users_generating', window: '1d')
      assert_equal 1, value(text, 'comfier_api_tokens')
      assert_equal 1, value(text, 'comfier_api_tokens_used', window: '1d')
    end

    test 'generations are counted by kind and status, with zeros for the rest' do
      text = render

      assert_equal Generation.image.succeeded.count, value(text, 'comfier_generations', kind: 'image',
                                                                                        status: 'succeeded')
      assert_equal Generation.video.failed.count, value(text, 'comfier_generations', kind: 'video', status: 'failed')
      assert_equal 0, value(text, 'comfier_generations', kind: 'model_3d', status: 'running')
      assert_equal Generation.where(workflow_name: 'Wan', status: :failed).count,
                   value(text, 'comfier_workflow_generations', workflow: 'Wan', kind: 'video', status: 'failed')
    end

    test 'a cancelled agent job is reported as cancelled, not failed' do
      failed = Generation.image.failed.count
      Generation.create!(user: users(:alice), workflow: workflows(:sd_image), prompt: 'x', kind: :image,
                         status: :failed, agent_state: 'cancelled')
      text = render

      assert_equal 1, value(text, 'comfier_generations', kind: 'image', status: 'cancelled')
      assert_equal failed, value(text, 'comfier_generations', kind: 'image', status: 'failed')
    end

    test 'in-progress generations report their detailed state and the oldest wait' do
      Generation.in_progress.delete_all
      Generation.create!(user: users(:alice), workflow: workflows(:sd_image), prompt: 'x', kind: :image,
                         status: :queued, agent_state: 'waiting_models', created_at: 10.minutes.ago)
      Generation.create!(user: users(:bob), workflow: workflows(:sd_image), prompt: 'y', kind: :image,
                         status: :running, created_at: 1.minute.ago)
      text = render

      assert_equal 1, value(text, 'comfier_generations_in_progress', kind: 'image', state: 'waiting_models')
      assert_equal 1, value(text, 'comfier_generations_in_progress', kind: 'image', state: 'running')
      assert_in_delta 600, value(text, 'comfier_generations_oldest_queued_seconds'), 30
    end

    test 'with nothing queued the oldest wait is zero' do
      Generation.in_progress.delete_all

      assert_equal 0, value(render, 'comfier_generations_oldest_queued_seconds')
    end

    test 'job attempts are counted by server and outcome' do
      backend = backends(:gpu)
      generation = generations(:alice_failed)
      JobAttempt.create!(generation:, backend:, attempt: 1, outcome: 'lost', infra: true)
      JobAttempt.create!(generation:, backend:, attempt: 2, outcome: 'failed')
      JobAttempt.create!(generation:, backend: nil, attempt: 3, outcome: 'failed')
      text = render

      assert_equal 1, value(text, 'comfier_job_attempts', server: 'GPU box', outcome: 'lost', infra: 'true')
      assert_equal 1, value(text, 'comfier_job_attempts', server: 'GPU box', outcome: 'failed', infra: 'false')
      assert_equal 1, value(text, 'comfier_job_attempts', server: '', outcome: 'failed', infra: 'false')
    end

    test 'durations are histograms by kind' do
      Generation.succeeded.update_all(status: 'failed') # rubocop:disable Rails/SkipsModelValidations
      base = { user: users(:alice), workflow: workflows(:sd_image), prompt: 'x', kind: :image, status: :succeeded }
      # A legacy job: ComfyUI's own run time, 45 s in the queue.
      Generation.create!(**base, created_at: 100.seconds.ago, processing_started_at: 55.seconds.ago, run_seconds: 8,
                                 completed_at: 40.seconds.ago)
      # An agent job: no run_seconds, timed from running_at to completed_at.
      Generation.create!(**base, created_at: 400.seconds.ago, running_at: 298.seconds.ago, completed_at: 98.seconds.ago,
                                 agent_state: 'completed')
      text = render

      assert_equal 2, value(text, 'comfier_generation_run_seconds_count', kind: 'image')
      assert_in_delta 208, value(text, 'comfier_generation_run_seconds_sum', kind: 'image'), 1
      assert_equal 0, value(text, 'comfier_generation_run_seconds_bucket', kind: 'image', le: '5')
      assert_equal 1, value(text, 'comfier_generation_run_seconds_bucket', kind: 'image', le: '10')
      assert_equal 1, value(text, 'comfier_generation_run_seconds_bucket', kind: 'image', le: '120')
      assert_equal 2, value(text, 'comfier_generation_run_seconds_bucket', kind: 'image', le: '300')
      assert_equal 2, value(text, 'comfier_generation_run_seconds_bucket', kind: 'image', le: '+Inf')
    end

    test 'queue wait and total time are measured from the request' do
      Generation.succeeded.update_all(status: 'failed') # rubocop:disable Rails/SkipsModelValidations
      Generation.create!(user: users(:alice), workflow: workflows(:sd_image), prompt: 'x', kind: :image,
                         status: :succeeded, created_at: 100.seconds.ago, processing_started_at: 55.seconds.ago,
                         run_seconds: 8, completed_at: 40.seconds.ago)
      text = render

      assert_in_delta 45, value(text, 'comfier_generation_queue_wait_seconds_sum', kind: 'image'), 1
      assert_in_delta 60, value(text, 'comfier_generation_total_seconds_sum', kind: 'image'), 1
      assert_equal 1, value(text, 'comfier_generation_total_seconds_bucket', kind: 'image', le: '120')
    end

    test 'a generation with no timings is left out of the histograms' do
      Generation.succeeded.update_all(status: 'failed') # rubocop:disable Rails/SkipsModelValidations
      Generation.create!(user: users(:alice), workflow: workflows(:sd_image), prompt: 'x', kind: :image,
                         status: :succeeded)

      text = render

      assert_nil value(text, 'comfier_generation_run_seconds_count', kind: 'image')
      assert_nil value(text, 'comfier_generation_total_seconds_count', kind: 'image')
    end

    test 'servers report whether they are up, and agents their state and free memory' do
      agent = create_agent_backend!(owner: users(:alice), name: 'Agent "one"', gpu_name: 'RTX 5090')
      bring_online!(agent, vram_free: 20.gigabytes, disk_free: { 'models' => 500.gigabytes, 'output' => 90.gigabytes })
      Generation.create!(user: users(:alice), workflow: workflows(:sd_image), prompt: 'x', kind: :image,
                         status: :running, backend: agent, agent_state: 'running')
      text = render
      server = 'Agent \\"one\\"'

      assert_equal 1, value(text, 'comfier_server_up', server:)
      assert_equal 1, value(text, 'comfier_server_up', server: 'GPU box')
      assert_equal 1, value(text, 'comfier_server_state', server:, state: 'idle')
      assert_equal agent.reload.vram_total, value(text, 'comfier_server_vram_total_bytes', server:)
      assert_equal 20.gigabytes, value(text, 'comfier_server_vram_free_bytes', server:)
      assert_equal 90.gigabytes, value(text, 'comfier_server_disk_free_bytes', server:)
      assert_equal 1, value(text, 'comfier_server_generations_in_progress', server:)
    end

    test 'servers are summarised and described' do
      agent = create_agent_backend!(owner: users(:alice), name: 'Agent "one"', gpu_name: 'RTX 5090')
      bring_online!(agent)
      text = render
      server = 'Agent \\"one\\"'
      agent.reload

      assert_equal 1, value(text, 'comfier_servers', connection_kind: 'agent', visibility: 'private')
      assert_equal 2, value(text, 'comfier_servers_online')

      assert_includes text, %(comfier_server_info{server="#{server}",connection_kind="agent",visibility="private",) +
                            %(gpu="#{agent.gpu_name}",agent_version="#{agent.agent_version}",) +
                            %(comfyui_version="#{agent.comfyui_version}"} 1)
    end

    test 'an agent that is not connected is down and offline, with no free-memory series' do
      create_agent_backend!(owner: users(:alice), name: 'Sleeper')
      text = render

      assert_equal 0, value(text, 'comfier_server_up', server: 'Sleeper')
      assert_equal 1, value(text, 'comfier_server_state', server: 'Sleeper', state: 'offline')
      assert_nil value(text, 'comfier_server_vram_free_bytes', server: 'Sleeper')
    end

    test 'deleted servers are left out' do
      backends(:gpu).update!(deleted_at: Time.current)

      assert_nil value(render, 'comfier_server_up', server: 'GPU box')
    end

    test 'the activity log is exposed as counters, with a zero for kinds not yet seen' do
      ActivityLog.delete_all
      2.times { ActivityLog.record(kind: :generation_failed, message: 'failed') }
      ActivityLog.record(kind: :login_failed, message: 'nope')
      text = render

      assert_includes text, '# TYPE comfier_activity_events_total counter'
      assert_equal 2, value(text, 'comfier_activity_events_total', kind: 'generation_failed')
      assert_equal 1, value(text, 'comfier_activity_events_total', kind: 'login_failed')
      assert_equal 0, value(text, 'comfier_activity_events_total', kind: 'generation_cancelled')
    end

    test 'workflows, reports, chat and storage are counted' do
      text = render

      assert_equal Workflow.where(kind: 'image', engine: 'comfyui', enabled: true).count,
                   value(text, 'comfier_workflows', kind: 'image', engine: 'comfyui', enabled: 'true')
      assert_equal ReportCase.open.count, value(text, 'comfier_report_cases', status: 'open')
      assert_equal Report.count, value(text, 'comfier_reports')
      assert_equal ChatConversation.count, value(text, 'comfier_chat_conversations')
      assert_equal ActiveStorage::Blob.sum(:byte_size), value(text, 'comfier_storage_bytes')
      assert_equal 0, value(text, 'comfier_model_downloads', status: 'running')
    end

    test 'Sidekiq totals and queues are reported' do
      text = render

      assert_equal 120, value(text, 'comfier_sidekiq_processed_total')
      assert_equal 4, value(text, 'comfier_sidekiq_failed_total')
      assert_equal 7, value(text, 'comfier_sidekiq_queue_size', queue: 'default')
      assert_in_delta 12.5, value(text, 'comfier_sidekiq_queue_latency_seconds', queue: 'default')
    end
  end
end

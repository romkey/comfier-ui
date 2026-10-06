# frozen_string_literal: true

require 'test_helper'

module Agent
  class ServerStylesTest < ActiveSupport::TestCase
    setup do
      @alice = users(:alice)
      @bob = users(:bob)
      @workflow = workflows(:sd_image)
      Backend.legacy.update_all(enabled: false) # rubocop:disable Rails/SkipsModelValidations
      @own = create_agent_backend!(owner: @alice)
      @other = create_agent_backend!(owner: @bob, name: 'Public box', visibility: 'public')
      [@own, @other].each { bring_online_for!(it, @workflow) }
    end

    test 'the router skips servers where the style is turned off' do
      ServerStyles.set!(@own, @workflow, enabled: false)
      gen = routing_job

      assert_equal @other, Router.route!(gen)
    end

    test 'with no other server the job fails with the reason' do
      ServerStyles.set!(@own, @workflow, enabled: false)
      @other.update!(visibility: 'private')

      error = assert_raises(Router::UnroutableError) { Router.route!(routing_job) }
      assert_match "doesn't run the #{@workflow.name} style", error.message
    end

    test 'turning a style off moves its waiting jobs to another server' do
      gen = queued_on(@own)

      assert ServerStyles.set!(@own, @workflow, enabled: false)
      assert_equal @other.id, gen.reload.backend_id
      assert_equal 'queued', gen.agent_state
    end

    test 'jobs pinned to the server fail with the reason' do
      gen = queued_on(@own, pinned_backend_id: @own.id)
      ServerStyles.set!(@own, @workflow, enabled: false)

      assert_equal 'failed', gen.reload.agent_state
      assert_match "doesn't run the #{@workflow.name} style", gen.error_message
    end

    test 'running jobs and other styles are left alone' do
      running = queued_on(@own, agent_state: 'running')
      other_style = create_agent_workflow!(name: 'Other style')
      other = queued_on(@own, workflow: other_style)

      ServerStyles.set!(@own, @workflow, enabled: false)

      assert_equal [@own.id, 'running'], [running.reload.backend_id, running.agent_state]
      assert_equal [@own.id, 'queued'], [other.reload.backend_id, other.agent_state]
    end

    test 'turning a style back on lets jobs route there again' do
      ServerStyles.set!(@own, @workflow, enabled: false)

      assert ServerStyles.set!(@own, @workflow, enabled: true)
      assert_not ServerStyles.set!(@own, @workflow, enabled: true)
      assert_equal @own, Router.route!(routing_job(pinned_backend_id: @own.id))
    end

    private

    def routing_job(**attrs)
      Generation.create!({ user: @alice, workflow: @workflow, prompt: 'x', kind: :image, status: :queued,
                           agent_state: 'routing', filled_workflow_json: { '1' => {} } }.merge(attrs))
    end

    def queued_on(backend, workflow: @workflow, **attrs)
      Generation.create!({ user: @alice, workflow:, prompt: 'x', kind: :image, status: :queued,
                           agent_state: 'queued', backend:, filled_workflow_json: { '1' => {} },
                           queued_at: Time.current }.merge(attrs))
    end
  end
end

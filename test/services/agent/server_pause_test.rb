# frozen_string_literal: true

require 'test_helper'

module Agent
  class ServerPauseTest < ActiveSupport::TestCase
    setup do
      @alice = users(:alice)
      @bob = users(:bob)
      @workflow = workflows(:sd_image)
      @own = create_agent_backend!(owner: @alice)
      @other = create_agent_backend!(owner: @bob, name: 'Public box', visibility: 'public')
      [@own, @other].each { bring_online_for!(it, @workflow) }
    end

    test 'pause reroutes queued jobs to another server' do
      gen = queued_on(@own)
      ServerPause.reroute_jobs!(@own.reload)

      assert_equal @other.id, gen.reload.backend_id
      assert_equal 'queued', gen.agent_state
    end

    test 'mine_only jobs park until the server resumes' do
      @alice.update!(backend_affinity: 'mine_only')
      gen = queued_on(@own)
      ServerPause.reroute_jobs!(@own.reload)

      assert_nil gen.reload.backend_id
      assert_equal 'routing', gen.agent_state
      assert_equal 'waiting_for_server', gen.agent_phase
    end

    private

    def queued_on(backend)
      Generation.create!(user: @alice, workflow: @workflow, prompt: 'x', kind: :image, status: :queued,
                         agent_state: 'queued', backend: backend, filled_workflow_json: { '1' => {} },
                         queued_at: Time.current)
    end
  end
end

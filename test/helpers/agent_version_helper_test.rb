# frozen_string_literal: true

require 'test_helper'

class AgentVersionHelperTest < ActionView::TestCase
  include AgentVersionHelper

  test 'agent_version_line flags an agent older or newer than the one Comfier ships' do
    expected = Agent::Version.expected
    major = Gem::Version.new(expected).segments.first

    assert_equal expected, agent_version_line(Backend.new(agent_version: expected))
    assert_includes agent_version_line(Backend.new(agent_version: '0.0.1')), 'Update available'
    assert_includes agent_version_line(Backend.new(agent_version: "#{major + 1}.0.0")), 'Newer than Comfier'
    assert_includes agent_version_line(Backend.new(agent_version: nil)), '—'
  end
end

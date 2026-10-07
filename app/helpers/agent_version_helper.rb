# frozen_string_literal: true

module AgentVersionHelper
  AGENT_VERSION_FLAGS = { outdated: ['Update available', 'Update the agent on this server.'],
                          newer: ['Newer than Comfier', 'Update Comfier to match.'] }.freeze

  # The agent version, flagged when it differs from the agent this build of Comfier ships.
  def agent_version_line(backend)
    return tag.span('—', class: 'text-secondary') if backend.agent_version.blank?

    label, advice = AGENT_VERSION_FLAGS[backend.agent_version_status]
    return backend.agent_version unless label

    title = "This Comfier ships agent #{Agent::Version.expected}. #{advice}"
    safe_join([backend.agent_version, ' ', tag.span(label, class: 'badge text-bg-warning-subtle fw-medium', title:)])
  end
end

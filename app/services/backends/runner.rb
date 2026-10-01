module Backends
  # One interface over the two kinds of server, so callers don't branch on connection_kind:
  #   submit(generation), cancel(generation), refresh_inventory(backend), download(backend, requirements)
  module Runner
    module_function

    # Routes each new job to the best legacy backend or agent server the user can use.
    def for(generation)
      return AgentRunner.new if generation.agent_job?

      AgentRunner.new
    end

    def for_backend(backend) = backend.agent? ? AgentRunner.new : LegacyRunner.new
  end
end

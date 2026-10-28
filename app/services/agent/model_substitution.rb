# frozen_string_literal: true

module Agent
  # Why a workflow's model files differ from server to server, applied in order: the server's own overrides
  # (ModelOverrides), then Apple Silicon's fp16 stand-ins for fp8 files (MacWeights). Everything that decides which
  # files a server needs or names in a job goes through here.
  class ModelSubstitution
    def initialize(backend, workflow)
      @overrides = ModelOverrides.new(backend, workflow)
      @mac = MacWeights.new(backend)
    end

    # The models the workflow needs on the server.
    def models(models) = @mac.models(@overrides.models(models))

    # The same, as downloads that fetch each stand-in afresh.
    def downloads(models) = @mac.downloads(@overrides.models(models))

    # The graph a job sends to the server.
    def rewrite(graph, models) = @mac.rewrite(@overrides.rewrite(graph, models), @overrides.models(models))

    # Why the substituted files can't run on the server.
    def problems(models, graph) = @overrides.problems(models, graph) + @mac.problems(@overrides.models(models))
  end
end

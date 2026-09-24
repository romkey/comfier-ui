# Picks which ComfyUI backend a user's generation goes to: their preferred backend when it's
# enabled, otherwise the reachable enabled backend with the shortest queue. Backends known to be
# missing a model the workflow needs are skipped.
class BackendSelector
  class NoBackendAvailable < StandardError
    def initialize(msg = 'No ComfyUI backend is available right now. Ask an admin to check the backends.') = super
  end

  def self.call(user, workflow = nil) = new(user, workflow).call

  def initialize(user, workflow = nil)
    @user = user
    @workflow = workflow
  end

  def call
    enabled = Backend.enabled.ordered.to_a
    raise NoBackendAvailable if enabled.empty?

    candidates = @workflow ? enabled.reject { it.missing_models(@workflow).any? } : enabled
    raise NoBackendAvailable, missing_models_message if candidates.empty?

    preferred = @user.preferred_backend
    return preferred if candidates.include?(preferred)
    return candidates.first if candidates.one?

    least_busy(candidates) || raise(NoBackendAvailable)
  end

  private

  def missing_models_message
    "No server has the models the #{@workflow.name} style needs yet. Ask an admin to install them."
  end

  def least_busy(candidates)
    candidates.filter_map do |backend|
      [backend, backend.client(open_timeout: 2, read_timeout: 5).queue_depth]
    rescue Comfyui::Error
      nil
    end.min_by(&:last)&.first
  end
end

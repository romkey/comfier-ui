# Loads what the studio page (studios/show) needs, so a failed submission can re-render it.
module StudioPage
  RECENT_LIMIT = 8

  private

  def load_studio(kind, workflow_id: nil)
    @kind = kind
    @workflows = Workflow.enabled.where(kind: kind.key).ordered.to_a
    @workflow = @workflows.find { it.id == workflow_id.to_i } || @workflows.first
    @recent = current_user.generations.where(kind: kind.key).recent.with_attached_outputs.limit(RECENT_LIMIT)
    @backends_available = Backend.enabled.exists?
    @queue_estimate = QueueEstimator.call
  end
end

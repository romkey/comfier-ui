# Loads what the studio page (studios/show) needs, so a failed submission can re-render it.
module StudioPage
  RECENT_LIMIT = 8

  private

  def load_studio(kind, workflow_id: nil)
    @kind = kind
    @workflows = Workflow.enabled.where(kind: kind.key).ordered.to_a
    @workflow = @workflows.find { it.id == workflow_id.to_i } || @workflows.first
    @recent = recent_generations(kind)
    @backends_available = Backend.enabled.exists?
    @queue_estimate = QueueEstimator.call
    kick_polls_for(current_user.generations.in_progress)
  end

  def recent_generations(kind)
    current_user.generations.where(kind: kind.key).recent.with_attached_outputs.with_attached_output_poster
                .with_album_art.limit(RECENT_LIMIT)
  end

  def kick_polls_for(generations)
    generations.find_each { PollGenerationJob.perform_later(it) }
  end
end

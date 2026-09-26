module GenerationTiming
  extend ActiveSupport::Concern

  # ComfyUI's execution_start / execution_success (or execution_error) timestamps from history.
  def record_processing_times!(result)
    started = result.processing_started_at
    ended = result.processing_ended_at
    return unless started && ended

    attrs = { processing_started_at: started, processing_ended_at: ended }
    attrs[:run_seconds] = result.run_seconds if result.run_seconds
    update!(attrs)
  end

  # Seconds from queue entry until ComfyUI started executing the workflow.
  def queue_wait_seconds
    return unless processing_started_at

    (processing_started_at - created_at).clamp(0, Float::INFINITY)
  end

  # Seconds ComfyUI spent executing the workflow (excludes queue wait and output download).
  def processing_seconds
    if processing_started_at && processing_ended_at
      (processing_ended_at - processing_started_at).clamp(0, Float::INFINITY)
    elsif run_seconds
      run_seconds
    end
  end
end

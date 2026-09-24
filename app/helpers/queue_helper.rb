module QueueHelper
  def queue_wait_label(seconds)
    return 'now' if seconds.to_i <= 5

    "about #{distance_of_time_in_words(seconds)}"
  end

  def queue_job_owner(generation)
    generation.user_id == current_user.id ? 'You' : generation.user.display_name
  end

  def queue_job_status(generation)
    if generation.running?
      tag.span(class: 'text-12') do
        safe_join([tag.span(class: 'status-dot status-success me-1', title: 'Running'), 'Running'])
      end
    else
      tag.span('Waiting', class: 'text-12 text-secondary')
    end
  end
end

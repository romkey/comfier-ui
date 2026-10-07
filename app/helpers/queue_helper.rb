module QueueHelper
  # distance_of_time_in_words already hedges most spans ("about 1 hour", "less than a minute").
  def queue_wait_label(seconds)
    return 'now' if seconds.to_i <= 5

    words = distance_of_time_in_words(seconds)
    words.start_with?('about', 'less', 'over', 'almost') ? words : "about #{words}"
  end

  def queue_job_owner(generation)
    generation.user_id == current_user.id ? 'You' : generation.user.display_name
  end

  # Waiting agent jobs also say why: finding a server, downloading models, jobs ahead, sent but not started.
  def queue_job_status(generation)
    if generation.running?
      tag.span(class: 'text-12') do
        safe_join([tag.span(class: 'status-dot status-success me-1', title: 'Running'), 'Running'])
      end
    else
      safe_join([tag.span('Waiting', class: 'text-12 text-secondary'),
                 (tag.div(queue_wait_reason(generation), class: 'text-12 text-secondary') if generation.agent_job?)])
    end
  end

  # The job page's progress line, minus its second person when the viewer isn't the job's owner.
  def queue_wait_reason(generation)
    line = agent_progress_line(generation)
    return line if generation.user_id == current_user.id || line != Agent::Router::WAITING_FOR_OWN

    "Waiting for the owner's server to come online"
  end
end

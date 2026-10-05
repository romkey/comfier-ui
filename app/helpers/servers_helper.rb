module ServersHelper
  AVAILABILITY_DOTS = { 'idle' => 'success', 'busy' => 'success', 'starting' => 'muted', 'offline' => 'muted',
                        'paused' => 'warning', 'busy_local' => 'warning', 'disk_low' => 'warning',
                        'error' => 'danger' }.freeze
  # Available and busy are normal; everything else gets a label.
  EXCEPTIONAL = %w[offline paused busy_local disk_low error starting].freeze
  BADGE_COLORS = { 'warning' => 'warning', 'danger' => 'danger', 'muted' => 'secondary', 'success' => 'success' }.freeze

  def server_availability(backend)
    state = Agent::Presence.availability(backend)
    color = AVAILABILITY_DOTS.fetch(state, 'muted')
    label = Agent::Presence.availability_label(backend)
    return tag.span(class: "status-dot status-#{color}", title: label) unless EXCEPTIONAL.include?(state)

    tag.span(label, class: "badge text-bg-#{BADGE_COLORS.fetch(color)}-subtle fw-medium")
  end

  def human_bytes(bytes) = bytes.to_i.positive? ? number_to_human_size(bytes, precision: 2) : '—'

  def gpu_line(backend)
    return tag.span('—', class: 'text-secondary') if backend.gpu_name.blank?

    [backend.gpu_name, (human_bytes(backend.vram_total) if backend.vram_total)].compact.join(' · ')
  end

  # "about 2 min", "about 2–3 min", or "probably a few minutes (first run on this server)".
  def duration_estimate(ms, confidence:, p90_ms: nil)
    return 'probably a few minutes (first run on this server)' if ms.nil? || confidence == 'low'

    low = short_duration(ms)
    return "about #{low}" if confidence == 'high' || p90_ms.nil? || p90_ms <= ms * 1.2

    "about #{range_duration(ms, p90_ms)}"
  end

  def short_duration(ms)
    seconds = (ms / 1000.0).round
    return "#{seconds} s" if seconds < 60
    return "#{(seconds / 60.0).round} min" if seconds < 3600

    "#{(seconds / 3600.0).round(1)} h"
  end

  def range_duration(low_ms, high_ms)
    low = (low_ms / 60_000.0).round
    high = (high_ms / 60_000.0).round
    return "#{short_duration(low_ms)}–#{short_duration(high_ms)}" if low < 1 || low == high

    "#{low}–#{high} min"
  end

  def eta_phrase(time)
    return if time.nil?

    seconds = time - Time.current
    return 'any moment' if seconds < 30

    "in about #{short_duration(seconds * 1000)}"
  end

  def speed_label(backend)
    speed = backend.backend_speed
    return tag.span('—', class: 'text-secondary') if speed.nil? || speed.n_workflows.zero?

    ratio = 1 / speed.speed_index
    text = ratio >= 1 ? "#{ratio.round(1)}× faster" : "#{(1 / ratio).round(1)}× slower"
    tag.span(text, class: ratio.between?(0.8, 1.25) ? 'text-secondary' : 'fw-medium')
  end

  def typical_wait(backend)
    queue = backend.generations.agent_waiting.count
    return tag.span('None', class: 'text-secondary') if queue.zero? && Agent::Presence.accepting?(backend)

    finish = Agent::Timeline.backlog_end(backend)
    wait = finish - Time.current
    wait.positive? ? short_duration(wait * 1000) : tag.span('None', class: 'text-secondary')
  end

  def download_line(download)
    parts = ["#{human_bytes(download.bytes_done)} of #{human_bytes(download.bytes_total)}"]
    parts << "#{human_bytes(download.speed_bps)}/s" if download.speed_bps.to_i.positive?
    eta = download.agent_eta
    parts << eta_phrase(eta) if eta && download.agent_state != 'queued'
    parts.join(' · ')
  end

  def availability_cell(record)
    return tag.span('—', class: 'text-secondary') unless record

    case record.status
    when 'ready' then tag.span(class: 'status-dot status-success', title: 'Ready')
    when 'needs_downloads'
      tag.span(record.download_progress_label, class: 'badge text-bg-warning-subtle fw-medium',
                                               title: record.download_progress_title)
    else
      tag.span('Blocked', class: 'badge text-bg-danger-subtle fw-medium',
                          title: Array(record.details['reasons']).join("\n"))
    end
  end

  def install_snippet(key)
    url = Agent::Dispatcher.base_url
    <<~TEXT
      git clone --depth 1 https://github.com/romkey/comfier-ui.git /tmp/comfier-ui
      cp -r /tmp/comfier-ui/comfyui/comfier_agent ComfyUI/custom_nodes/comfier_agent
      export COMFIER_URL=#{url}
      export COMFIER_API_KEY=#{key}
    TEXT
  end

  def docker_snippet(key)
    <<~TEXT
      environment:
        COMFIER_URL: #{Agent::Dispatcher.base_url}
        COMFIER_API_KEY: #{key}
    TEXT
  end

  # Other users' jobs on someone else's server show as style and name only.
  def queue_entry_label(generation, _backend)
    return generation.title if current_user.admin? || generation.user_id == current_user.id

    "#{generation.style_name} · #{generation.user.display_name}"
  end

  def rejected_key_hint(backend)
    key = backend.backend_keys.where.not(last_rejected_at: nil).order(last_rejected_at: :desc).first
    return unless key && key.last_rejected_at > 1.day.ago

    safe_join(['A connection ', friendly_time(key.last_rejected_at), " used key #{key.display}, which is ",
               "#{key.last_rejected_reason}. Update the server with the current key."])
  end
end

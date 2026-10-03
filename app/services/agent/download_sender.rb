# frozen_string_literal: true

module Agent
  # Sends queued downloads to an agent, one at a time per server. Downloads that jobs are waiting
  # for go first, then first come first served.
  module DownloadSender
    IN_FLIGHT = %w[sent downloading verifying cancelling].freeze
    PENDING = (%w[queued] + IN_FLIGHT).freeze

    module_function

    def flush_queue!(backend)
      return false unless Presence.online?(backend)

      sent = false
      loop do
        in_flight = ModelDownload.where(backend_id: backend.id, agent_state: IN_FLIGHT).count
        limit = backend.agent_download_concurrency
        break if limit.positive? && in_flight >= limit

        download = next_download(backend)
        break unless download

        send!(download)
        sent = true
      end
      sent
    end

    def next_download(backend)
      ModelDownload.where(backend_id: backend.id, agent_state: 'queued')
                   .order(Arel.sql("CASE WHEN for_generation_ids = '[]'::jsonb THEN 1 ELSE 0 END"), :created_at)
                   .first
    end

    def send!(download)
      backend = download.backend
      reason = disk_problem(backend, download)
      return DownloadLifecycle.fail!(download, 'disk_full', reason) if reason

      message = {
        'type' => 'model.download', 'download_id' => download.agent_download_id, 'url' => download.url,
        'folder' => download.directory, 'filename' => download.name, 'sha256' => download.sha256,
        'bytes' => download.bytes_total, 'headers' => CredentialHeaders.for_url(download.url, backend:),
        'overwrite' => false
      }.compact
      download.update!(agent_state: 'sent', status: :running, sent_at: Time.current, started_at: Time.current)
      Commands.send_message(backend.id, message)
      true
    end

    def disk_problem(backend, download)
      return unless download.bytes_total.to_i.positive?

      free = Presence.disk_free(backend)
      return unless free && free - download.bytes_total < AgentTiming::MIN_FREE_DISK_GB.gigabytes

      "#{backend.name} has #{ActiveSupport::NumberHelper.number_to_human_size(free)} free, not enough for " \
        "#{ActiveSupport::NumberHelper.number_to_human_size(download.bytes_total)} plus " \
        "#{AgentTiming::MIN_FREE_DISK_GB} GB headroom."
    end

    # After a reconnect: in-flight downloads the agent no longer lists are sent again.
    def resend_unlisted!(backend, active_downloads)
      listed = active_downloads.filter_map { it['download_id'] }
      ModelDownload.where(backend_id: backend.id, agent_state: IN_FLIGHT - %w[cancelling])
                   .where.not(agent_download_id: listed)
                   .update_all(agent_state: 'queued', status: 'queued') # rubocop:disable Rails/SkipsModelValidations
    end

    def eta(download)
      return 5.minutes.from_now unless download.bytes_total.to_i.positive?

      remaining = download.bytes_total - download.bytes_done.to_i
      queued = download.agent_state == 'queued' ? queued_ahead_seconds(download) : 0
      Time.current + queued + (remaining.to_f / download_speed(download))
    rescue URI::InvalidURIError
      nil
    end

    # Bytes per second: the live speed, else what this server has seen from the host, else a default.
    def download_speed(download)
      return download.speed_bps if download.speed_bps.to_i.positive?

      host = URI.parse(download.url).host.to_s
      Perf::Transfers.download_bps(download.backend, host) || Perf::Transfers::DEFAULT_BPS['download']
    end

    def queued_ahead_seconds(download)
      ahead = ModelDownload.where(backend_id: download.backend_id, agent_state: PENDING)
                           .where(created_at: ...download.created_at)
      ahead.sum { (it.bytes_total.to_i - it.bytes_done.to_i).clamp(0, nil) } / Perf::Transfers::DEFAULT_BPS['download']
    end
  end
end

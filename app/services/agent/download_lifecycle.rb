# frozen_string_literal: true

module Agent
  # model.download.* events, cancels, and what happens to jobs waiting on a download.
  module DownloadLifecycle
    module_function

    def find(backend, download_id) = ModelDownload.find_by(backend_id: backend.id, agent_download_id: download_id)

    def progress!(backend, message)
      download = find(backend, message['download_id'])
      return unless download && DownloadSender::IN_FLIGHT.include?(download.agent_state)

      state = download.agent_state == 'cancelling' ? 'cancelling' : message['state'] || 'downloading'
      download.update_columns(agent_state: state, # rubocop:disable Rails/SkipsModelValidations
                              bytes_done: message['bytes_done'].to_i, speed_bps: message['speed_bps'],
                              bytes_total: message['bytes_total'] || download.bytes_total, updated_at: Time.current)
      broadcast(download)
    end

    def completed!(backend, message)
      download = find(backend, message['download_id'])
      return unless download && DownloadSender::PENDING.include?(download.agent_state)

      bytes = message['bytes'] || download.bytes_total
      download.update!(agent_state: 'completed', status: :succeeded, finished_at: Time.current,
                       sha256: message['sha256'] || download.sha256, bytes_total: bytes, bytes_done: bytes)
      BackendModel.find_or_create_by!(backend_id: backend.id, folder: download.directory, filename: download.name)
      Perf::Transfers.observe_download!(download)
      RecomputeAvailabilityJob.perform_later(backend_id: backend.id)
      release_waiting!(download)
      DownloadSender.flush_queue!(backend)
    end

    def failed!(backend, message)
      download = find(backend, message['download_id'])
      return unless download && DownloadSender::PENDING.include?(download.agent_state)

      shutdown = message['reason'] == 'cancelled_by_shutdown'
      return download.update!(agent_state: 'queued', status: :queued, bytes_done: 0) if shutdown

      fail!(download, message['reason'], message['detail'])
    end

    def cancelled!(backend, message)
      download = find(backend, message['download_id'])
      return unless download && DownloadSender::PENDING.include?(download.agent_state)

      finish!(download, 'cancelled', 'The download was cancelled.')
    end

    def fail!(download, reason, detail = nil)
      finish!(download, 'failed', DownloadMessages.for(download, reason, detail), reason:, detail:)
    end

    def cancel_by_user!(download, user: nil)
      return false unless DownloadSender::PENDING.include?(download.agent_state)

      if download.agent_state == 'queued'
        finish!(download, 'cancelled', 'The download was cancelled.')
      else
        download.update!(agent_state: 'cancelling')
        send_cancel(download.backend_id, download.agent_download_id)
      end
      if user
        ActivityLog.record(kind: :model_download_cancelled, user:, subject: download.backend,
                           message: "Cancelled download of #{download.directory}/#{download.name}")
      end
      true
    end

    # hello.active_downloads: adopt progress for ones we know, cancel ones we don't.
    def reconcile_listed!(backend, entries)
      entries.each do |entry|
        download = find(backend, entry['download_id'])
        if download.nil? || DownloadSender::PENDING.exclude?(download.agent_state)
          send_cancel(backend.id, entry['download_id'])
        elsif download.agent_state == 'queued'
          download.update!(agent_state: 'downloading', status: :running)
        end
      end
    end

    def send_cancel(backend_id, download_id)
      Commands.send_message(backend_id, { 'type' => 'model.download.cancel', 'download_id' => download_id.to_s })
    end

    def finish!(download, state, message, reason: nil, detail: nil)
      download.update!(agent_state: state, status: :failed, error_message: message.truncate(1000),
                       agent_reason: reason, agent_detail: detail, finished_at: Time.current)
      reroute_waiting!(download, message)
      DownloadSender.flush_queue!(download.backend)
    end

    def release_waiting!(download)
      backend = download.backend
      waiting_for(download).find_each do |gen|
        next unless Availability.compute(gen.workflow, backend).ready?

        gen.agent_transition!(from: 'waiting_models', to: 'queued', queued_at: Time.current)
      end
      Dispatcher.dispatch_for!(backend)
      Timeline.schedule(backend)
    end

    # Jobs that needed this file try another server, keep waiting for the user's own server, or fail
    # with the download's reason.
    def reroute_waiting!(download, message)
      waiting_for(download).find_each do |gen|
        JobLifecycle.reroute!(gen, exclude: download.backend, from: 'waiting_models')
        gen.reload.update_columns(error_message: message) if gen.agent_state == 'failed' # rubocop:disable Rails/SkipsModelValidations
      end
    end

    def waiting_for(download)
      Generation.where(id: download.for_generation_ids, backend_id: download.backend_id, agent_state: 'waiting_models')
    end

    def broadcast(download)
      return unless Store.once_per?("download_broadcast:#{download.id}", ttl: 1)

      Turbo::StreamsChannel.broadcast_refresh_later_to(:model_downloads)
      Turbo::StreamsChannel.broadcast_refresh_later_to(
        [download.backend, :downloads], target: "server_downloads_#{download.backend.id}"
      )
      Presence.publish!(download.backend)
    end
  end
end

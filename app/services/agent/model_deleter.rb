# frozen_string_literal: true

module Agent
  # Deletes models from agent servers (model.delete), and reloads them: delete, then download again.
  # A model other workflows also use is deleted all the same. Deleting cancels downloads of the same files
  # first, so they don't put the files straight back or keep them busy.
  module ModelDeleter
    MIN_AGENT = '0.4.15'
    FAILURES_TTL = 1.day
    FAILURES_KEPT = 20

    Outcome = Data.define(:deleted, :queued)

    module_function

    def supported?(backend) = backend.agent? && backend.model_downloads_enabled? && backend.agent_at_least?(MIN_AGENT)

    # Why supported? is false, in words for the server's owner.
    def blocker(backend)
      return "#{backend.name} doesn't allow model downloads, which deleting needs too." unless
        backend.model_downloads_enabled?

      "Deleting models needs agent #{MIN_AGENT} or later on #{backend.name}." unless backend.agent_at_least?(MIN_AGENT)
    end

    # Returns how many deletes were sent; 0 when the server can't take them or is offline.
    def delete!(backend, models, user:)
      return 0 if models.empty? || !supported?(backend) || !Presence.online?(backend)

      cancel_downloads!(backend, models)
      models.each { send_delete(backend, it) }
      record(backend, user, "Deleted #{models.size} model(s) on #{backend.name}", models)
      models.size
    end

    # A file already downloading is fetching a fresh copy, so it keeps going rather than being deleted.
    def reload!(backend, selection, user:)
      return Outcome.new(deleted: 0, queued: 0) if !supported?(backend) || !Presence.online?(backend)

      downloading = pending(backend).to_set { [it.directory, it.name] }
      stale = selection.installed.reject { downloading.include?(ServerModels.key(it)) }
      deleted = delete!(backend, stale, user:)
      queued = DownloadPlanner.manual!(backend, selection.downloads, user:)
      Outcome.new(deleted:, queued: queued.size)
    end

    def cancel_downloads!(backend, models)
      keys = models.to_set { ServerModels.key(it) }
      pending(backend).select { keys.include?([it.directory, it.name]) }.each { DownloadLifecycle.cancel_by_user!(it) }
    end

    def pending(backend) = ModelDownload.where(backend_id: backend.id, agent_state: DownloadSender::PENDING).to_a

    def send_delete(backend, model)
      target = if model['engine'] then { 'engine' => model['engine'], 'model' => model['filename'] }
               else { 'folder' => model['folder'], 'filename' => model['filename'] }
               end
      Commands.send_message(backend.id, { 'type' => 'model.delete', 'delete_id' => "x_#{SecureRandom.hex(8)}" }
                                          .merge(target))
    end

    # model.deleted: the inventory that follows has the full picture; until then the file is gone here too.
    def deleted!(backend, message)
      folder, filename = path(message)
      BackendModel.where(backend_id: backend.id, folder:, filename:).delete_all
      RecomputeAvailabilityJob.perform_later(backend_id: backend.id)
    end

    def failed!(backend, message)
      text = "Couldn't delete #{path(message).compact.join('/')}: #{message['detail'].presence || message['reason']}"
      failures = [{ 'message' => text, 'at' => Time.current.iso8601 }] + failures(backend)
      Store.write_json(failures_key(backend), failures.first(FAILURES_KEPT), ttl: FAILURES_TTL)
      ActivityLog.record(kind: :model_delete_failed, subject: backend, message: "#{text} (#{backend.name})")
      broadcast(backend)
    end

    def failures(backend) = Array(Store.read_json(failures_key(backend)))

    def clear_failures!(backend) = Store.delete(failures_key(backend))

    def failures_key(backend) = "model_delete_failures:#{backend.id}"

    def path(message)
      message['engine'] ? message.values_at('engine', 'model') : message.values_at('folder', 'filename')
    end

    def record(backend, user, message, models)
      return unless user

      ActivityLog.record(kind: :model_delete_requested, user:, subject: backend, message:,
                         details: { files: models.map { ServerModels.key(it).join('/') } })
    end

    def broadcast(backend)
      Turbo::StreamsChannel.broadcast_refresh_later_to([backend, :downloads], target: "server_downloads_#{backend.id}")
    end
  end
end

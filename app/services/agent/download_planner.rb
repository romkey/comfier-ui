# frozen_string_literal: true

module Agent
  # Creates ModelDownload rows for agent servers, one per missing file, and links waiting jobs to
  # them. A file already queued or downloading on that server is reused rather than duplicated.
  module DownloadPlanner
    module_function

    def ensure_downloads!(backend, models, generation:, auto:)
      models.each { plan!(backend, it, user_id: generation.user_id, auto:, generation_id: generation.id) }
      DownloadSender.flush_queue!(backend)
    end

    # Admin- or owner-requested downloads. Returns the downloads created or reused.
    def manual!(backend, models, user:)
      planned = models.filter_map do |model|
        next if model['url'].blank? && model['engine'].blank?

        plan!(backend, model, user_id: user&.id, auto: false)
      end
      if user && planned.any?
        ActivityLog.record(kind: :model_download_requested, user:, subject: backend,
                           message: "Requested #{planned.size} model download(s) on #{backend.name}",
                           details: { files: planned.map { "#{it.directory}/#{it.name}" } })
      end
      DownloadSender.flush_queue!(backend)
      planned
    end

    def plan!(backend, model, user_id:, auto:, generation_id: nil)
      existing = ModelDownload.find_by(backend_id: backend.id, directory: model['folder'], name: model['filename'],
                                       agent_state: DownloadSender::PENDING)
      if existing
        existing.update!(for_generation_ids: (existing.for_generation_ids | [generation_id].compact))
        return existing
      end

      ModelDownload.create!(
        backend:, directory: model['folder'], name: model['filename'], url: model['url'], sha256: model['sha256'],
        engine: model['engine'],
        bytes_total: model['bytes'], agent_state: 'queued', agent_download_id: "d_#{SecureRandom.hex(8)}",
        requested_by_user_id: user_id, auto:, for_generation_ids: [generation_id].compact, status: :queued,
        via: 'agent'
      )
    end

    # A cancelled job no longer waits on its downloads; automatic downloads keep going.
    def release_generation!(generation)
      ModelDownload.where('for_generation_ids @> ?', [generation.id].to_json).find_each do |download|
        download.update!(for_generation_ids: download.for_generation_ids - [generation.id])
      end
    end
  end
end

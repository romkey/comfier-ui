module Metrics
  module Sections
    # Everything else people make and admins manage: workflows, model downloads, reports, chat and stored files.
    class Content < Base
      def collect
        workflows
        downloads
        reports
        chat
        storage
      end

      private

      def workflows
        counts = Workflow.group(:kind, :engine, :enabled).count
        gauge('comfier_workflows', 'Workflows, by kind, engine and whether they are enabled.',
              counts.map { |(kind, engine, enabled), count| [{ kind:, engine:, enabled: }, count] })
      end

      def downloads
        gauge('comfier_model_downloads', 'Model downloads on record, by status.',
              by(:status, ModelDownload.group(:status).count, ModelDownload.statuses.keys))
        remaining = ModelDownload.active.where.not(bytes_total: nil)
                                 .sum('GREATEST(bytes_total - COALESCE(bytes_done, 0), 0)')
        gauge('comfier_model_download_bytes_remaining', 'Bytes still to fetch across downloads in progress.', remaining)
      end

      def reports
        gauge('comfier_report_cases', 'Content report cases, by status.',
              by(:status, ReportCase.group(:status).count, ReportCase.statuses.keys))
        gauge('comfier_reports', 'Individual content reports received.', Report.count)
      end

      def chat
        gauge('comfier_chat_conversations', 'Chat conversations.', ChatConversation.count)
        counts = ChatMessage.group(:role, :status).count
        gauge('comfier_chat_messages', 'Chat messages, by role and status.',
              counts.map { |(role, status), count| [{ role:, status: }, count] })
        gauge('comfier_video_script_requests', 'Video script requests, by status.',
              by(:status, VideoScriptRequest.group(:status).count))
      end

      def storage
        gauge('comfier_storage_blobs', 'Files held in storage (inputs, results, posters and the like).',
              ActiveStorage::Blob.count)
        gauge('comfier_storage_bytes', 'Total size of the files held in storage.', ActiveStorage::Blob.sum(:byte_size))
      end
    end
  end
end

# Waits for a running model download to finish, then confirms the file is on the backend.
class PollModelDownloadJob < ApplicationJob
  INTERVAL = 5.seconds

  queue_as :default

  def perform(download)
    return unless download.running?

    client = download.backend.client
    return wait_or_time_out(download) unless finished?(download, client)

    confirm(download)
  rescue Comfyui::ConnectionError
    wait_or_time_out(download)
  rescue Comfyui::Error => e
    download.fail!(e.message)
  end

  private

  def finished?(download, client)
    if download.node?
      result = client.result(download.comfy_prompt_id)
      raise Comfyui::Error, result.error_message if result.error?

      !result.pending?
    else
      status = client.manager_queue_status
      !status['is_processing'] && status['in_progress_count'].to_i.zero?
    end
  end

  def confirm(download)
    backend = download.backend
    backend.refresh_inventory!([download.directory])
    if backend.model_status(download.requirement) == :installed
      download.succeed!
    else
      download.fail!("#{backend.name} finished, but #{download.requirement.path} isn't there. Check the ComfyUI log.")
    end
  end

  def wait_or_time_out(download)
    return download.fail!('Timed out waiting for the download to finish') if download.timed_out?

    self.class.set(wait: INTERVAL).perform_later(download)
  end
end

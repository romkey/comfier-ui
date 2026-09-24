# Starts a model download on its backend: through the Comfier downloader node when the backend has it,
# otherwise through ComfyUI-Manager when Manager's catalog has the exact file for the same folder.
class StartModelDownloadJob < ApplicationJob
  queue_as :default

  def perform(download)
    return unless download.queued?

    client = download.backend.client
    if client.downloader_node?
      start_with_node(download, client)
    elsif client.manager_version
      start_with_manager(download, client)
    else
      download.fail!("Install the Comfier downloader node on #{download.backend.name} to download models " \
                     '(see the README), or enable ComfyUI-Manager.')
    end
    PollModelDownloadJob.set(wait: PollModelDownloadJob::INTERVAL).perform_later(download) if download.running?
  rescue Comfyui::Error => e
    download.fail!(e.message)
  end

  private

  def start_with_node(download, client)
    prompt_id = client.submit(download.downloader_graph)
    download.update!(via: :node, comfy_prompt_id: prompt_id, status: :running, started_at: Time.current)
  end

  def start_with_manager(download, client)
    entry = client.manager_catalog.find { Comfyui::ManagerCatalog.path(it) == download.requirement.path }
    return download.fail!(not_in_catalog(download)) unless entry

    client.manager_install_model(entry.except('installed', 'description').merge('ui_id' => "comfier-#{download.id}"))
    download.update!(via: :manager, status: :running, started_at: Time.current)
  rescue Comfyui::Forbidden
    download.fail!("ComfyUI-Manager on #{download.backend.name} refused to download models. Set " \
                   'network_mode = personal_cloud in ComfyUI/user/__manager/config.ini and restart ComfyUI.')
  end

  def not_in_catalog(download)
    "ComfyUI-Manager only downloads models from its catalog, and it has no #{download.name} for " \
      "#{download.directory}. Install the Comfier downloader node on #{download.backend.name} instead."
  end
end

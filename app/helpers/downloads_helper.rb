# Lines describing a model download in progress.
module DownloadsHelper
  include ServersHelper

  def download_line(download)
    done = human_bytes(download.bytes_done)
    parts = [download.bytes_total.to_i.positive? ? "#{done} of #{human_bytes(download.bytes_total)}" : "#{done} so far"]
    parts << "#{human_bytes(download.speed_bps)}/s" if download.speed_bps.to_i.positive?
    eta = download.agent_eta
    parts << eta_phrase(eta) if eta && download.agent_state != 'queued'
    parts.join(' · ')
  end
end

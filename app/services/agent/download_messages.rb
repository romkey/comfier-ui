# frozen_string_literal: true

module Agent
  # What to tell people when a model download fails, from the agent's reason code.
  module DownloadMessages
    MESSAGES = {
      'disabled' => "%<server>s doesn't allow model downloads.",
      'invalid' => "%<server>s refused %<file>s: the folder or file name isn't allowed.",
      'host_not_allowed' => '%<server>s only downloads from approved sites, and %<host>s isn\'t one of them.',
      'extension_not_allowed' => "%<server>s doesn't accept this file type (%<file>s).",
      'exists' => '%<file>s already exists on %<server>s with different contents.',
      'disk_full' => 'Not enough disk space on %<server>s for %<file>s.',
      'too_large' => '%<file>s is larger than %<server>s allows.',
      'http_error' => 'Downloading %<file>s from %<host>s failed (%<detail>s).',
      'hash_mismatch' => "%<file>s didn't match its expected checksum, so it was deleted.",
      'size_mismatch' => "%<file>s wasn't the expected size, so it was deleted.",
      'network' => 'Downloading %<file>s from %<host>s kept failing because of network errors.',
      'cancelled_by_shutdown' => '%<server>s shut down during the download.'
    }.freeze
    AUTH_FAILURE = /\b40[13]\b/

    module_function

    def for(download, reason, detail)
      host = host_of(download.url)
      if reason == 'http_error' && detail.to_s.match?(AUTH_FAILURE)
        return "#{host} refused the download (#{detail}). Check the access token for #{host}."
      end

      template = MESSAGES[reason] || "Downloading %<file>s failed: #{reason}."
      text = format(template, server: download.backend.name, file: download.name, host:,
                              detail: detail.presence || 'no detail')
      detail.present? && reason != 'http_error' ? "#{text} #{detail}" : text
    end

    def host_of(url)
      return 'Hugging Face' if url.blank? # engine downloads come from the Hugging Face hub

      URI.parse(url.to_s).host || 'the source'
    rescue URI::InvalidURIError
      'the source'
    end
  end
end

# A HEAD request to a model's download link, for its size and, from Hugging Face, its sha256. Hugging Face
# `resolve` links report the LFS hash and size in X-Linked-Etag / X-Linked-Size.
module ModelLinkHead
  module_function

  # { bytes:, sha256: } (either may be missing), or nil when the link doesn't answer. Only https links are tried.
  def attributes(url, known_sha256: nil)
    response = head(url)
    return unless found?(response)

    attributes_from(response, known_sha256)
  end

  def found?(response) = response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)

  # A redirect's own Content-Length is the redirect body, not the file.
  def attributes_from(response, known_sha256)
    size = response['x-linked-size'] || (response['content-length'] unless response.is_a?(Net::HTTPRedirection))
    etag = response['x-linked-etag'].to_s.delete('"')
    attrs = { bytes: size&.to_i }.compact
    attrs[:sha256] = etag if etag.match?(/\A\h{64}\z/) && known_sha256.blank?
    attrs
  end

  def head(url)
    uri = URI.parse(url)
    return unless uri.is_a?(URI::HTTPS)

    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
      http.head(uri.request_uri, 'User-Agent' => 'Comfier')
    end
  end
end

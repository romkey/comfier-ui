# Streams a generation's file. Only allowlisted image, video, and audio types are shown inline; everything else
# (3D models included) downloads, and the browser is told not to guess the type.
#
# Files are served with byte ranges, because browsers fetch video in pieces and come back for more whenever the
# viewer plays, seeks, or loops. A blob never changes once stored, so responses can be cached for good. Files on
# the Disk service go out through Rack::Files, which lets Rack::Sendfile hand them to a front proxy when
# SENDFILE_HEADER is set.
module OutputServing
  extend ActiveSupport::Concern
  include ActiveStorage::Streaming

  private

  def serve_output(attachment, download: false)
    blob = attachment.blob
    apply_output_serving_headers(blob)
    return head :not_modified if output_fresh?(blob)

    disposition = output_disposition(blob, download:)
    if disk_path(blob)
      serve_output_file(blob, disposition)
    else
      stream_output_blob(blob, disposition)
    end
  end

  def apply_output_serving_headers(blob)
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Content-Security-Policy'] = "default-src 'none'; sandbox"
    response.headers['Accept-Ranges'] = 'bytes'
    response.headers['ETag'] = output_etag(blob)
    response.headers['Cache-Control'] = 'private, max-age=31536000, immutable'
  end

  def output_etag(blob) = %("#{blob.checksum || blob.key}")

  def output_fresh?(blob)
    request.headers['If-None-Match'].to_s.split(/\s*,\s*/).include?(output_etag(blob))
  end

  def output_disposition(blob, download: false)
    kind = !download && Agent::Outputs.inline?(blob.content_type) ? 'inline' : 'attachment'
    ActionDispatch::Http::ContentDisposition.format(disposition: kind, filename: blob.filename.sanitized)
  end

  def disk_path(blob)
    service = blob.service
    return unless service.respond_to?(:path_for)

    path = service.path_for(blob.key)
    path if File.file?(path)
  end

  # The same thing ActiveStorage::DiskController does, with our headers.
  def serve_output_file(blob, disposition)
    status, headers, body = ::Rack::Files.new(nil).serving(request, disk_path(blob))
    self.status = status
    self.response_body = body
    headers.each { |name, value| response.headers[name] = value unless name.casecmp?('x-cascade') }
    response.headers['Content-Type'] = blob.content_type.presence || 'application/octet-stream'
    response.headers['Content-Disposition'] = disposition
  end

  def stream_output_blob(blob, disposition)
    range = request.headers['Range']
    if range.present?
      send_blob_byte_range_data blob, range, disposition:
    else
      response.headers['Content-Length'] = blob.byte_size.to_s
      send_blob_stream blob, disposition:
    end
  end
end

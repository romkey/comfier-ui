# Streams a generation output. Only allowlisted image, video, and audio types are shown inline;
# everything else (3D models included) downloads. The browser is told not to guess the type.
module OutputServing
  extend ActiveSupport::Concern
  include ActiveStorage::Streaming

  private

  def serve_output(attachment)
    blob = attachment.blob
    apply_output_serving_headers
    stream_output_blob(blob, output_disposition(blob))
  end

  def apply_output_serving_headers
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Content-Security-Policy'] = "default-src 'none'; sandbox"
  end

  def output_disposition(blob)
    kind = Agent::Outputs.inline?(blob.content_type) ? 'inline' : 'attachment'
    ActionDispatch::Http::ContentDisposition.format(disposition: kind, filename: blob.filename.sanitized)
  end

  def stream_output_blob(blob, disposition)
    range = request.headers['Range']
    if range.present?
      send_blob_byte_range_data blob, range, disposition:
    else
      response.headers['Accept-Ranges'] = 'bytes'
      response.headers['Content-Length'] = blob.byte_size.to_s
      send_blob_stream blob, disposition:
    end
  end
end

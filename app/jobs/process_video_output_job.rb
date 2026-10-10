# Readies a finished video result for the browser: probes each video output, makes it browser-safe if it isn't
# (see VideoNormalizer), records its size and length on the blob for the player, then builds the poster from the
# final file. A file that can't be fixed is kept as it was, with a warning in the log.
class ProcessVideoOutputJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS = 5
  RETRY_WAIT = 2.seconds

  def perform(generation, attempt = 0)
    generation.reload
    return unless generation.succeeded? && generation.video?

    if videos(generation).empty?
      self.class.set(wait: RETRY_WAIT).perform_later(generation, attempt + 1) if attempt < MAX_ATTEMPTS
      return
    end

    videos(generation).each { process(generation, it) }
    finish(generation.reload)
  end

  private

  # The poster comes from the final file. Saving it redraws the result's card and page; when there's no new
  # poster, a touch does, so the player picks up the size and length recorded above.
  def finish(generation)
    had_poster = generation.output_poster.attached?
    poster_saved = VideoPosterExtractor.call(generation) && !had_poster
    generation.update!(updated_at: Time.current) unless poster_saved
  end

  def videos(generation) = generation.outputs.select { it.content_type.to_s.start_with?('video/') }

  def process(generation, attachment)
    return if attachment.blob.metadata['normalized']

    attachment.blob.open do |file|
      probe = VideoProbe.call(file.path)
      next warn(generation, attachment, "ffprobe couldn't read it") unless probe

      outcome = VideoNormalizer.new(file.path, probe, content_type: attachment.content_type).call
      if outcome.path
        replace(attachment, outcome, probe)
      else
        warn(generation, attachment, outcome.error) if outcome.error
        record(attachment.blob, probe, outcome.error ? 'failed' : 'none')
      end
    end
  end

  def replace(attachment, outcome, original)
    probe = VideoProbe.call(outcome.path) || original
    old = attachment.blob
    blob = File.open(outcome.path, 'rb') do |io|
      ActiveStorage::Blob.create_and_upload!(
        io:, filename: "#{old.filename.base}.mp4", content_type: 'video/mp4', identify: false,
        metadata: metadata(probe, outcome.action, old).merge('identified' => true, 'analyzed' => true)
      )
    end
    swap!(attachment, old, blob)
    Rails.logger.info("ProcessVideoOutputJob: #{outcome.action} #{old.filename} for generation " \
                      "#{attachment.record_id} (#{original.video_codec}/#{original.pix_fmt}, " \
                      "index #{original.index_first ? 'first' : 'last'})")
  ensure
    FileUtils.rm_f(outcome.path)
  end

  # The attachment keeps its id and place among the outputs; agent upload records follow the file, so a repeated
  # completion message can't attach the old one again.
  def swap!(attachment, old, blob)
    ActiveRecord::Base.transaction do
      attachment.update!(blob:)
      GenerationOutput.where(storage_key: old.key).find_each { it.update!(storage_key: blob.key) }
    end
    old.purge_later
  end

  def record(blob, probe, action)
    blob.update!(metadata: blob.metadata.merge(metadata(probe, action, nil)))
  end

  def metadata(probe, action, old)
    probe.to_metadata.merge('normalized' => action.to_s, 'normalized_from' => old && original_format(old)).compact
  end

  def original_format(blob) = "#{blob.content_type} #{blob.byte_size} bytes"

  def warn(generation, attachment, detail)
    Rails.logger.warn("ProcessVideoOutputJob: left #{attachment.filename} for generation #{generation.id} " \
                      "as it was: #{detail}")
  end
end

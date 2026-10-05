# Pulls the first frame from a generation's primary video output for grid thumbnails.
class VideoPosterExtractor
  def self.call(generation) = new(generation).call
  def self.available? = system(ffmpeg_path, '-version', out: File::NULL, err: File::NULL)

  def self.ffmpeg_path = ENV.fetch('FFMPEG', 'ffmpeg')

  def initialize(generation)
    @generation = generation
  end

  def call
    return false unless @generation.video? && @generation.succeeded?
    return true if @generation.output_poster.attached?

    video = primary_video_output
    return false unless video

    frame = extract_frame(video)
    return false if frame.blank?

    save_poster_frame(frame)
    true
  end

  private

  def primary_video_output
    @generation.outputs.find { |output| output.content_type.to_s.start_with?('video/') }
  end

  def save_poster_frame(frame)
    @generation.output_poster.attach(
      io: StringIO.new(frame),
      filename: 'poster.jpg',
      content_type: 'image/jpeg'
    )
    @generation.update!(updated_at: Time.current)
  end

  def extract_frame(attachment)
    return unless self.class.available?

    attachment.blob.open do |file|
      stdout, stderr, status = Open3.capture3(
        self.class.ffmpeg_path, '-hide_banner', '-loglevel', 'error', '-y',
        '-i', file.path, '-frames:v', '1', '-q:v', '2', '-f', 'image2pipe', '-'
      )
      stdout = stdout.b
      return stdout if status.success? && !stdout.empty?

      detail = stderr.to_s.dup.force_encoding(Encoding::UTF_8)
      detail = detail.scrub.lines.last&.strip
      Rails.logger.warn("VideoPosterExtractor: ffmpeg failed for generation #{@generation.id}: #{detail}")
      nil
    end
  end
end

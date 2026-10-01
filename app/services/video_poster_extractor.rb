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

    video = @generation.outputs.find { |output| output.content_type.to_s.start_with?('video/') }
    return false unless video

    frame = extract_frame(video)
    return false if frame.blank?

    @generation.output_poster.attach(
      io: StringIO.new(frame),
      filename: 'poster.jpg',
      content_type: 'image/jpeg'
    )
    @generation.touch
    true
  end

  private

  def extract_frame(attachment)
    return unless self.class.available?

    attachment.blob.open do |file|
      stdout, stderr, status = Open3.capture3(
        self.class.ffmpeg_path, '-hide_banner', '-loglevel', 'error', '-y',
        '-i', file.path, '-frames:v', '1', '-q:v', '2', '-f', 'image2pipe', '-'
      )
      return stdout.b if status.success? && stdout.present?

      Rails.logger.warn(
        "VideoPosterExtractor: ffmpeg failed for generation #{@generation.id}: #{stderr.to_s.lines.last&.strip}"
      )
      nil
    end
  end
end

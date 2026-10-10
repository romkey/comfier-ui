# Makes a video one every browser plays: H.264 (yuv420p, even dimensions) with AAC or no audio, in an MP4 whose
# index comes first. A file that only has the index at the end, or the wrong container, is remuxed without
# touching the picture; anything else is re-encoded. VIDEO_NORMALIZE=remux never re-encodes, and off leaves files
# alone.
class VideoNormalizer
  PROFILES = ['Baseline', 'Constrained Baseline', 'Main', 'High'].freeze
  PIXEL_FORMATS = %w[yuv420p yuvj420p].freeze
  MODES = %w[transcode remux off].freeze

  Outcome = Data.define(:action, :path, :error)

  def self.mode = ENV.fetch('VIDEO_NORMALIZE', 'transcode').presence_in(MODES) || 'transcode'
  def self.ffmpeg_path = ENV.fetch('FFMPEG', 'ffmpeg')

  # :none, :remux or :transcode, for a VideoProbe::Result of a file stored with content_type. ffprobe names MP4
  # and QuickTime the same way, so the stored type tells them apart.
  def self.action_for(probe, content_type:, mode: self.mode)
    return :none if mode == 'off'

    needed = needed_action(probe, content_type)
    needed == :transcode && mode == 'remux' ? :remux : needed
  end

  def self.needed_action(probe, content_type)
    return :transcode unless streams_ok?(probe)
    return :remux unless content_type == 'video/mp4' && probe.index_first

    :none
  end

  def self.streams_ok?(probe)
    probe.video_codec == 'h264' && PROFILES.include?(probe.profile) && PIXEL_FORMATS.include?(probe.pix_fmt) &&
      probe.width.to_i.even? && probe.height.to_i.even? && [nil, 'aac'].include?(probe.audio_codec)
  end

  def initialize(input, probe, content_type:, mode: self.class.mode)
    @input = input
    @probe = probe
    @content_type = content_type
    @mode = mode
  end

  # Writes the browser-safe copy to a temp file (the caller deletes it) and says what it did. path is nil when
  # nothing was needed or ffmpeg failed; error says why it failed.
  def call
    action = self.class.action_for(@probe, content_type: @content_type, mode: @mode)
    return Outcome.new(action: :none, path: nil, error: nil) if action == :none

    output = Tempfile.create(['normalized', '.mp4']).tap(&:close).path
    run(action == :remux ? remux_args : transcode_args, action, output)
  end

  private

  def run(args, action, output)
    _stdout, stderr, status = Open3.capture3(self.class.ffmpeg_path, '-hide_banner', '-loglevel', 'error', '-y',
                                             '-i', @input, *args, output)
    return Outcome.new(action:, path: output, error: nil) if status.success? && File.size?(output)

    FileUtils.rm_f(output)
    Outcome.new(action:, path: nil, error: stderr.to_s.scrub.lines.last&.strip.presence || 'ffmpeg failed')
  rescue Errno::ENOENT
    Outcome.new(action:, path: nil, error: 'ffmpeg is not installed')
  end

  # The picture is kept as is; audio that isn't AAC is converted so the MP4 plays everywhere.
  def remux_args
    audio = @probe.audio_codec.nil? || @probe.audio_codec == 'aac' ? %w[-c:a copy] : %w[-c:a aac -b:a 160k]
    ['-map', '0:v:0', '-map', '0:a:0?', '-c:v', 'copy', *audio, '-movflags', '+faststart', '-f', 'mp4']
  end

  def transcode_args
    ['-map', '0:v:0', '-map', '0:a:0?', '-c:v', 'libx264', '-profile:v', 'high', '-pix_fmt', 'yuv420p',
     '-preset', 'medium', '-crf', '18', '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2',
     '-c:a', 'aac', '-b:a', '160k', '-movflags', '+faststart', '-f', 'mp4']
  end
end

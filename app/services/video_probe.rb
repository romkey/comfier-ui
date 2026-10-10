# What's inside a video file, from ffprobe plus a look at the MP4 box order: enough to tell whether every browser
# can play it as it is, and to size the player before it loads.
class VideoProbe
  Result = Data.define(:container, :video_codec, :profile, :pix_fmt, :width, :height, :duration, :audio_codec,
                       :index_first) do
    def to_metadata
      { 'width' => width, 'height' => height, 'duration' => duration, 'video_codec' => video_codec,
        'pix_fmt' => pix_fmt, 'audio_codec' => audio_codec }.compact
    end
  end

  def self.ffprobe_path = ENV.fetch('FFPROBE', 'ffprobe')
  def self.call(path) = new(path).call

  def initialize(path)
    @path = path
  end

  # nil when ffprobe is missing or can't read the file.
  def call
    data = ffprobe
    return unless data

    video = data['streams'].find { it['codec_type'] == 'video' }
    audio = data['streams'].find { it['codec_type'] == 'audio' }
    Result.new(container: data.dig('format', 'format_name'), video_codec: video&.dig('codec_name'),
               profile: video&.dig('profile'), pix_fmt: video&.dig('pix_fmt'), width: video&.dig('width'),
               height: video&.dig('height'), duration: duration(data, video), audio_codec: audio&.dig('codec_name'),
               index_first: index_first)
  end

  private

  def ffprobe
    stdout, status = Open3.capture2(self.class.ffprobe_path, '-v', 'error', '-print_format', 'json',
                                    '-show_format', '-show_streams', @path)
    return unless status.success?

    data = JSON.parse(stdout)
    data if data['streams'].is_a?(Array)
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def duration(data, video)
    value = video&.dig('duration') || data.dig('format', 'duration')
    value&.to_f&.round(2)
  end

  # Whether the MP4 index (moov) comes before the media (mdat), so playback can start before the whole file has
  # arrived. Walks the top-level boxes; nil for files that aren't MP4/QuickTime.
  def index_first
    File.open(@path, 'rb') do |file|
      while (type, body = next_box(file))
        return true if type == 'moov'
        return false if type == 'mdat'

        file.seek(body, IO::SEEK_CUR)
      end
    end
  end

  # The next box's type and how many bytes of it follow its header, or nil at the end or on a malformed box.
  def next_box(file)
    header = file.read(8)
    return if header.to_s.bytesize < 8

    size, type = header.unpack('Na4')
    size = file.read(8).to_s.unpack1('Q>').to_i - 8 if size == 1
    [type, size - 8] if size >= 8
  end
end

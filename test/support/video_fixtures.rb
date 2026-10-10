# Small real video files made with ffmpeg's test sources, for tests that need a browser or ffprobe to read them.
module VideoFixtures
  DIR = Rails.root.join('tmp/video_fixtures')

  # Default: one second of H.264 yuv420p with AAC audio in an MP4 whose index comes first (what browsers want).
  CLIPS = {
    good: { ext: 'mp4', video: %w[-c:v libx264 -pix_fmt yuv420p], audio: %w[-c:a aac], faststart: true },
    index_last: { ext: 'mp4', video: %w[-c:v libx264 -pix_fmt yuv420p], audio: %w[-c:a aac], faststart: false },
    yuv444: { ext: 'mp4', video: %w[-c:v libx264 -pix_fmt yuv444p], audio: [], faststart: true },
    mpeg4: { ext: 'mp4', video: %w[-c:v mpeg4], audio: [], faststart: true },
    odd_size: { ext: 'mp4', video: %w[-c:v libx264 -pix_fmt yuv444p], audio: [], faststart: true, size: '65x47' },
    mp3_audio: { ext: 'mp4', video: %w[-c:v libx264 -pix_fmt yuv420p], audio: %w[-c:a libmp3lame], faststart: true },
    quicktime: { ext: 'mov', video: %w[-c:v libx264 -pix_fmt yuv420p], audio: %w[-c:a aac], faststart: true },
    webm: { ext: 'webm', video: %w[-c:v libvpx-vp9 -b:v 200k], audio: [], faststart: false }
  }.freeze
  TYPES = { 'mp4' => 'video/mp4', 'mov' => 'video/quicktime', 'webm' => 'video/webm' }.freeze

  def ffmpeg_available? = system('ffmpeg', '-version', out: File::NULL, err: File::NULL)

  def video_fixture(name)
    spec = CLIPS.fetch(name)
    path = DIR.join("#{name}-#{Process.pid}.#{spec[:ext]}")
    return path.to_s if path.exist?

    FileUtils.mkdir_p(DIR)
    system('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
           '-f', 'lavfi', '-i', "testsrc=size=#{spec.fetch(:size, '64x48')}:rate=10:duration=1",
           *(spec[:audio].empty? ? [] : %w[-f lavfi -i sine=frequency=440:duration=1]),
           *spec[:video], *spec[:audio], *(spec[:faststart] ? %w[-movflags +faststart] : []), '-shortest',
           path.to_s, exception: true)
    path.to_s
  end

  def attach_video(generation, name, content_type: nil)
    path = video_fixture(name)
    type = content_type || TYPES.fetch(File.extname(path).delete_prefix('.'))
    generation.outputs.attach(io: File.open(path, 'rb'), filename: "clip#{File.extname(path)}", content_type: type,
                              identify: false)
    generation.outputs.last
  end
end

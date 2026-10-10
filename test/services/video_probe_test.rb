require 'test_helper'

class VideoProbeTest < ActiveSupport::TestCase
  setup { skip 'ffmpeg required' unless ffmpeg_available? }

  test 'reads codec, pixel format, size, length, audio, and where the index is' do
    probe = VideoProbe.call(video_fixture(:good))

    assert_equal 'h264', probe.video_codec
    assert_equal 'yuv420p', probe.pix_fmt
    assert_equal [64, 48], [probe.width, probe.height]
    assert_in_delta 1.0, probe.duration, 0.2
    assert_equal 'aac', probe.audio_codec
    assert probe.index_first
  end

  test 'notices an index at the end of the file' do
    assert_not VideoProbe.call(video_fixture(:index_last)).index_first
  end

  test 'has no index answer for a file that is not MP4' do
    probe = VideoProbe.call(video_fixture(:webm))

    assert_equal 'vp9', probe.video_codec
    assert_nil probe.index_first
  end

  test 'is nil for something ffprobe can not read' do
    Tempfile.create('junk') do |file|
      file.write('not a video')
      file.close

      assert_nil VideoProbe.call(file.path)
    end
  end
end

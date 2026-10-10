require 'test_helper'

class VideoNormalizerTest < ActiveSupport::TestCase
  setup { skip 'ffmpeg required' unless ffmpeg_available? }

  def action(name, type = 'video/mp4', mode: 'transcode')
    VideoNormalizer.action_for(VideoProbe.call(video_fixture(name)), content_type: type, mode:)
  end

  test 'leaves a browser-safe MP4 alone' do
    assert_equal :none, action(:good)
  end

  test 'remuxes when only the index or the container is wrong' do
    assert_equal :remux, action(:index_last)
    assert_equal :remux, action(:quicktime, 'video/quicktime')
  end

  test 're-encodes pictures browsers may not show' do
    %i[yuv444 mpeg4 odd_size mp3_audio].each { assert_equal :transcode, action(it), it }

    assert_equal :transcode, action(:webm, 'video/webm')
  end

  test 'remux mode never re-encodes and off does nothing' do
    assert_equal :remux, action(:yuv444, mode: 'remux')
    assert_equal :none, action(:yuv444, mode: 'off')
  end

  TYPES = { '.webm' => 'video/webm', '.mov' => 'video/quicktime' }.freeze

  test 'what it writes is browser-safe' do
    %i[index_last yuv444 odd_size mp3_audio webm quicktime].each do |name|
      input = video_fixture(name)
      type = TYPES.fetch(File.extname(input), 'video/mp4')
      outcome = VideoNormalizer.new(input, VideoProbe.call(input), content_type: type).call
      result = VideoProbe.call(outcome.path)

      assert_equal :none, VideoNormalizer.action_for(result, content_type: 'video/mp4'), name
    ensure
      FileUtils.rm_f(outcome&.path)
    end
  end

  test 'reports an ffmpeg failure instead of raising' do
    probe = VideoProbe.call(video_fixture(:index_last))
    outcome = with_env('FFMPEG' => '/nonexistent/ffmpeg') do
      VideoNormalizer.new(video_fixture(:index_last), probe, content_type: 'video/mp4').call
    end

    assert_nil outcome.path
    assert_match(/not installed/, outcome.error)
  end
end

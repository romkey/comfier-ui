require 'test_helper'

class VideoPosterExtractorTest < ActiveSupport::TestCase
  setup do
    @generation = users(:alice).generations.create!(
      workflow: workflows(:wan_video), prompt: 'Waves', kind: :video, status: :succeeded
    )
    @generation.outputs.attach(
      io: StringIO.new('fake-video'),
      filename: 'clip.mp4',
      content_type: 'video/mp4'
    )
  end

  test 'attaches a jpeg poster from the first video frame' do
    skip 'ffmpeg required' unless VideoPosterExtractor.available?

    Tempfile.create(['clip', '.mp4']) do |file|
      system(
        VideoPosterExtractor.ffmpeg_path, '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=c=black:s=64x64:d=0.1', '-y', file.path, exception: true
      )
      @generation.outputs.purge
      @generation.outputs.attach(io: File.open(file.path), filename: 'clip.mp4', content_type: 'video/mp4')

      assert VideoPosterExtractor.call(@generation)

      assert_predicate @generation.output_poster, :attached?
      assert_equal 'image/jpeg', @generation.output_poster.blob.content_type
      assert_predicate @generation.output_poster.blob.byte_size, :positive?
    end
  end

  test 'does nothing when ffmpeg is unavailable' do
    with_env('FFMPEG' => '/nonexistent/ffmpeg') do
      assert_not VideoPosterExtractor.call(@generation)
    end

    assert_not @generation.output_poster.attached?
  end
end

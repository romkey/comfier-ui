require 'test_helper'

class ExtractVideoPosterJobTest < ActiveJob::TestCase
  setup do
    @generation = users(:alice).generations.create!(
      workflow: workflows(:wan_video), prompt: 'Waves', kind: :video, status: :running
    )
  end

  test 'retries when outputs are not attached yet' do
    @generation.succeed!

    assert_enqueued_with(job: ExtractVideoPosterJob, args: [@generation, 1]) do
      ExtractVideoPosterJob.perform_now(@generation)
    end
  end

  test 'extracts once a video output exists' do
    skip 'ffmpeg required' unless VideoPosterExtractor.available?

    @generation.succeed!
    file = Tempfile.new(['clip', '.mp4'])
    system(
      VideoPosterExtractor.ffmpeg_path, '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=black:s=64x64:d=0.1', '-y', file.path, exception: true
    )
    @generation.outputs.attach(io: File.open(file.path), filename: 'clip.mp4', content_type: 'video/mp4')

    ExtractVideoPosterJob.perform_now(@generation, ExtractVideoPosterJob::MAX_ATTEMPTS)

    assert_predicate @generation.reload.output_poster, :attached?
    file.close!
  end
end

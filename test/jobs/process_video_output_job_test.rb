require 'test_helper'

class ProcessVideoOutputJobTest < ActiveJob::TestCase
  setup do
    @generation = users(:alice).generations.create!(
      workflow: workflows(:wan_video), prompt: 'Waves', kind: :video, status: :running
    )
  end

  test 'retries when outputs are not attached yet' do
    @generation.succeed!

    assert_enqueued_with(job: ProcessVideoOutputJob, args: [@generation, 1]) do
      ProcessVideoOutputJob.perform_now(@generation)
    end
  end

  test 'jobs queued under the old name still run' do
    @generation.succeed!

    assert_enqueued_with(job: ExtractVideoPosterJob, args: [@generation, 1]) do
      ExtractVideoPosterJob.perform_now(@generation)
    end
  end

  test 'a browser-safe video keeps its file, gains its size and length, and gets a poster' do
    skip 'ffmpeg required' unless ffmpeg_available?
    @generation.succeed!
    output = attach_video(@generation, :good)
    blob_id = output.blob_id

    ProcessVideoOutputJob.perform_now(@generation, ProcessVideoOutputJob::MAX_ATTEMPTS)

    output.reload

    assert_equal blob_id, output.blob_id
    assert_equal({ 'width' => 64, 'height' => 48, 'normalized' => 'none' },
                 output.blob.metadata.slice('width', 'height', 'normalized'))
    assert_predicate @generation.reload.output_poster, :attached?
  end

  test 'a video browsers may not show is replaced in place by a browser-safe MP4' do
    skip 'ffmpeg required' unless ffmpeg_available?
    @generation.succeed!
    output = attach_video(@generation, :quicktime)
    old = output.blob
    upload = GenerationOutput.create!(generation: @generation, upload_id: 'u_1', node: 'n', filename: 'clip.mov',
                                      kind: 'video', mime: 'video/quicktime', bytes: old.byte_size,
                                      storage_key: old.key)

    assert_enqueued_with(job: ActiveStorage::PurgeJob) do
      ProcessVideoOutputJob.perform_now(@generation, ProcessVideoOutputJob::MAX_ATTEMPTS)
    end

    output.reload

    assert_not_equal old.id, output.blob_id
    assert_equal ['video/mp4', 'clip.mp4', 'remux'],
                 [output.content_type, output.filename.to_s, output.blob.metadata['normalized']]
    assert output.blob.metadata['analyzed']
    assert_equal output.blob.key, upload.reload.storage_key
    output.blob.open do |file|
      assert_equal :none, VideoNormalizer.action_for(VideoProbe.call(file.path), content_type: 'video/mp4')
    end
  end

  test 'a file ffmpeg can not fix is left as it was' do
    skip 'ffmpeg required' unless ffmpeg_available?
    @generation.succeed!
    output = attach_video(@generation, :yuv444)
    blob_id = output.blob_id

    with_env('VIDEO_NORMALIZE' => 'transcode', 'FFMPEG' => '/nonexistent/ffmpeg') do
      ProcessVideoOutputJob.perform_now(@generation, ProcessVideoOutputJob::MAX_ATTEMPTS)
    end

    assert_equal blob_id, output.reload.blob_id
    assert_equal 'failed', output.blob.metadata['normalized']
  end

  test 'the player gets the recorded size' do
    skip 'ffmpeg required' unless ffmpeg_available?
    @generation.succeed!
    attach_video(@generation, :good)
    ProcessVideoOutputJob.perform_now(@generation, ProcessVideoOutputJob::MAX_ATTEMPTS)

    html = ApplicationController.render(inline: '<%= output_preview(@generation.outputs.first, controls: true) %>',
                                        assigns: { generation: @generation.reload })

    assert_match(/width="64"/, html)
    assert_match(/height="48"/, html)
  end
end

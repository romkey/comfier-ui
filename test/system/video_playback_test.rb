require 'application_system_test_case'

# Plays a real H.264 clip in Chrome every way a viewer reaches a video, and checks frames are drawn: the video has
# no error, has decoded a frame, knows its width, and its clock moves.
class VideoPlaybackTest < ApplicationSystemTestCase
  PLAYING = <<~JS.freeze
    (() => { const v = document.querySelector('video.output-media');
      return !!v && !v.error && v.readyState >= 2 && v.videoWidth > 0 && v.currentTime > 0 })()
  JS

  setup do
    skip 'ffmpeg required' unless ffmpeg_available?
    @generation = users(:alice).generations.create!(
      workflow: workflows(:wan_video), prompt: 'Waves at night', kind: :video, status: :running
    )
    @generation.succeed!
    attach_video(@generation, :good)
    ProcessVideoOutputJob.perform_now(@generation, ProcessVideoOutputJob::MAX_ATTEMPTS)
    @generation.reload
  end

  test 'from Results, a click opens the result and the video plays' do
    sign_in_as users(:alice)
    visit generations_path
    click_on 'Waves at night'

    assert_current_path generation_path(@generation)
    assert_plays
    assert_no_active_storage_requests
  end

  test 'after Back and Forward' do
    sign_in_as users(:alice)
    visit generations_path
    click_on 'Waves at night'

    assert_plays
    go_back

    assert_current_path generations_path
    go_forward

    assert_current_path generation_path(@generation)
    assert_plays
  end

  test 'after the page refreshes itself with a morph' do
    sign_in_as users(:alice)
    visit generation_path(@generation)

    assert_plays
    execute_script("window.morphed = false; document.addEventListener('turbo:morph', () => { window.morphed = true })")
    execute_script("Turbo.visit(location.href, { action: 'replace' })")

    assert_eventually { evaluate_script('window.morphed') }
    assert_plays
  end

  test 'long after the page was opened, the file can still be fetched in pieces' do
    sign_in_as users(:alice)
    visit generation_path(@generation)

    assert_plays

    travel 2.hours do
      status = evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        fetch(document.querySelector('video.output-media').currentSrc,
              { headers: { Range: 'bytes=0-1' }, cache: 'no-store' }).then(r => done(r.status))
      JS

      assert_equal 206, status
    end
  end

  test 'on the Shared page and from a public link' do
    @generation.share!
    @generation.create_public_link!
    sign_in_as users(:bob)

    visit shared_path(@generation)

    assert_plays

    visit public_share_path(@generation.public_token)

    assert_plays
  end

  test 'a video that will not load says so, offers Reload, and is logged' do
    blob = @generation.outputs.first.blob
    FileUtils.rm_f(blob.service.path_for(blob.key))
    sign_in_as users(:alice)

    visit generation_path(@generation)
    execute_script("document.querySelector('video.output-media').play().catch(() => {})")

    assert_selector '.video-player-notice', text: "didn't load"
    assert_button 'Reload'
    assert_eventually { ActivityLog.media_failed.exists?(subject: @generation) }
  end

  private

  def assert_plays
    assert_selector 'video.output-media[data-video-player-target]', visible: :all
    execute_script(<<~JS)
      const v = document.querySelector('video.output-media'); v.muted = true; v.play().catch(() => {})
    JS
    assert_eventually(-> { "the video didn't play: #{media_state}" }) { evaluate_script(PLAYING) }
  end

  def media_state
    evaluate_script(<<~JS)
      (() => { const v = document.querySelector('video.output-media');
        return v && { error: v.error && v.error.code, network: v.networkState, ready: v.readyState,
                      width: v.videoWidth, time: v.currentTime, src: v.currentSrc } })()
    JS
  end

  def assert_no_active_storage_requests
    urls = evaluate_script("performance.getEntriesByType('resource').map(e => e.name)")

    assert_empty(urls.grep(%r{/rails/active_storage/}))
    assert(urls.any? { it.include?("/results/#{@generation.id}/outputs/") })
  end

  def assert_eventually(message = 'condition never became true', timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk(message.respond_to?(:call) ? message.call : message) if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.2
    end
    pass
  end
end

require 'application_system_test_case'

# Plays a real clip in Chrome through the waveform player, every way a listener reaches it.
class AudioPlaybackTest < ApplicationSystemTestCase
  PLAYING = 'document.querySelector("audio") === window.playingAudio && !window.playingAudio.paused'.freeze

  setup do
    skip 'ffmpeg required' unless ffmpeg_available?
    workflow = Workflow.create!(name: 'Music', kind: 'audio',
                                graph: { '1' => { 'class_type' => 'Music', 'inputs' => { 'text' => '{{prompt}}' } } })
    @generation = users(:alice).generations.create!(workflow:, prompt: 'A quiet melody')
    @generation.outputs.attach(io: StringIO.new(wav_audio), filename: 'melody.wav', content_type: 'audio/wav')
    @generation.update!(status: :succeeded)
    @blob = @generation.outputs.first.blob
    GenerateAudioWaveformJob.perform_now(@blob)
    sign_in_as users(:alice)
  end

  test 'waveform plays, seeks with the keyboard, changes speed and mutes' do
    visit generation_path(@generation)

    assert_player_ready
    click_on 'Play'

    assert_button 'Pause'
    assert_eventually { evaluate_script('document.querySelector("audio").currentTime > 0') }
    click_on 'Pause'
    find('.audio-player-seek', visible: :all).send_keys(:end)

    assert_eventually { evaluate_script('document.querySelector("audio").currentTime > 3.5') }
    select '1.5×', from: 'Speed'
    click_on 'Mute'

    assert_eventually { evaluate_script('document.querySelector("audio").playbackRate === 1.5') }
    assert_selector 'button[aria-pressed="true"]', text: 'Unmute'
  end

  test 'clicking and dragging the waveform seeks, playing or paused' do
    visit generation_path(@generation)

    assert_player_ready
    pointer { |action, wave, at| action.move_to(wave, at[0.75], 0).click }

    assert_eventually { current_time.between?(2.5, 3.5) }
    assert_button 'Play'
    assert_equal current_time.floor, evaluate_script('Number(document.querySelector(".audio-player-seek").value)').floor
    play_on_a_loop
    pointer { |action, wave, at| action.move_to(wave, at[0.1], 0).click_and_hold.move_to(wave, at[0.9], 0).release }

    assert_eventually { current_time > 3.2 }
    pointer { |action, wave, at| action.move_to(wave, at[0], 0).click }

    assert_eventually { current_time < 1 }
    assert evaluate_script(PLAYING)
  end

  test 'shared and public results have the player, grids keep their compact controls' do
    @generation.share!
    @generation.create_public_link!
    visit generations_path(kind: 'audio')

    assert_selector 'audio[controls]'
    assert_no_selector '.audio-player'
    visit shared_path(@generation)

    assert_player_ready
    visit public_share_path(@generation.public_token)

    assert_player_ready
  end

  test 'old audio keeps the browser controls while its waveform is prepared on first view' do
    @blob.update!(metadata: @blob.metadata.except(AudioWaveform::KEY))
    visit generation_path(@generation)

    assert_text 'Preparing waveform…'
    assert_selector 'audio[controls]'
    GenerateAudioWaveformJob.perform_now(@blob)

    assert_player_ready
  end

  test 'a page refresh leaves the song playing, even one that brings album art' do
    visit generation_path(@generation)

    assert_player_ready
    play_on_a_loop
    art = generations(:alice_done)
    art.outputs.attach(io: StringIO.new('png'), filename: 'art.png', content_type: 'image/png')
    @generation.update!(album_art_generation: art)
    execute_script('window.audioMorphed = false; document.addEventListener("turbo:morph", ' \
                   '() => { window.audioMorphed = true }, { once: true }); ' \
                   'Turbo.visit(location.href, { action: "replace" })')

    assert_eventually { evaluate_script('window.audioMorphed') }
    assert_selector '.output-audio-cover'
    assert_player_ready
    assert_button 'Pause'
    assert evaluate_script(PLAYING)
  end

  test 'leaving the page stops the song, and coming back gives a working player' do
    visit generation_path(@generation)

    assert_player_ready
    play_on_a_loop
    click_on 'Results', match: :first

    assert_eventually { evaluate_script('window.playingAudio.paused') }
    go_back

    assert_player_ready
    click_on 'Play'

    assert_button 'Pause'
    assert_eventually { evaluate_script('document.querySelector("audio").currentTime > 0') }
  end

  test 'undecodable waveforms leave the native audio controls available' do
    @generation.outputs.purge
    @generation.outputs.attach(io: StringIO.new('broken'), filename: 'broken.mp3', content_type: 'audio/mpeg')
    GenerateAudioWaveformJob.perform_now(@generation.outputs.first.blob)
    visit generation_path(@generation)

    assert_text 'Waveform unavailable. You can still use the audio player.'
    assert_selector 'audio[controls]'
    assert_no_selector '.audio-player-interface'
  end

  test 'the waveform follows the theme, and narrow screens keep every control inside the player' do
    visit generation_path(@generation)

    assert_player_ready
    dark = wave_color
    page.current_window.resize_to(375, 900)
    execute_script('document.documentElement.dataset.bsTheme = "light"')

    assert_eventually { wave_color != dark }
    assert_button 'Play'
    assert_select 'Speed'
    assert_button 'Mute'
    assert evaluate_script(<<~JS)
      (() => {
        const player = document.querySelector('.audio-player').getBoundingClientRect();
        return [...document.querySelectorAll('.audio-player button, .audio-player select')].every(control => {
          const rect = control.getBoundingClientRect();
          return rect.left >= player.left && rect.right <= player.right;
        });
      })()
    JS
  ensure
    page.current_window.resize_to(1280, 900)
  end

  private

  def assert_player_ready
    assert_selector '.audio-player-interface', visible: true
    assert_eventually do
      evaluate_script('!!document.querySelector("[data-audio-player-target=waveform] > div")?.shadowRoot' \
                      '?.querySelector("canvas")')
    end
    assert_no_selector 'audio[controls]', visible: true
  end

  # The clip is four seconds long, so it loops to still be playing when the test looks.
  def play_on_a_loop
    execute_script('window.playingAudio = document.querySelector("audio"); window.playingAudio.loop = true')
    click_on 'Play'

    assert_button 'Pause'
  end

  def current_time = evaluate_script('document.querySelector("audio").currentTime')

  # Real pointer input lands on whatever is on top at that spot, as a listener's mouse does. Offsets are from the
  # waveform's centre, so `at[fraction]` is that fraction of the way along it.
  def pointer
    wave = find('.audio-player-waveform').native
    width = evaluate_script('document.querySelector(".audio-player-waveform").getBoundingClientRect().width')
    at = ->(fraction) { ((fraction - 0.5) * (width - 4)).round }
    yield(page.driver.browser.action, wave, at).perform
  end

  def wave_color
    evaluate_script('Stimulus.getControllerForElementAndIdentifier(document.querySelector(".audio-player"), ' \
                    '"audio-player").wave.options.waveColor')
  end
end

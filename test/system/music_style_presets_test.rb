require 'application_system_test_case'

class MusicStylePresetsSystemTest < ApplicationSystemTestCase
  setup do
    page.driver.browser.manage.window.resize_to(1280, 1000)
    Workflow.create!(name: 'Music', kind: :audio, graph: {
                       '1' => { 'class_type' => 'Music',
                                'inputs' => { 'text' => '{{prompt}}', 'lyrics' => '{{lyrics}}' } }
                     })
    Workflow.create!(name: 'Music remix', kind: :audio, graph: Workflow.find_by!(name: 'Music').graph)
  end

  test 'creates and applies a personal preset without replacing lyrics' do
    user = users(:alice)
    sign_in_as user
    visit new_music_style_preset_path

    fill_in 'Music style', with: 'Gentle acoustic folk'
    fill_in 'Name', with: 'My folk'
    click_on 'Save preset'

    assert_text 'Music style preset saved.'

    visit audio_studio_path
    fill_in 'Lyrics', with: 'Hello spring'
    select 'My folk', from: 'Saved music style'

    assert_field 'Music style', with: 'Gentle acoustic folk'
    assert_no_field 'Describe what you want'
    fill_in 'Music style', with: 'Gentle folk with flute'
    click_on 'Music remix'

    assert_field 'Music style', with: 'Gentle folk with flute'
    assert_field 'Lyrics', with: 'Hello spring'
    click_on 'Generate'

    assert_text 'Queued.'
    assert_equal 'Gentle acoustic folk', user.music_style_presets.find_by!(name: 'My folk').description
  end

  test 'empty styles show a settings link and allow typing a style directly on mobile' do
    sign_in_as users(:alice)
    page.driver.browser.manage.window.resize_to(390, 1000)
    visit audio_studio_path

    assert_no_selector '#music_style_preset'
    fill_in 'Music style', with: 'Bright synth pop'
    fill_in 'Lyrics', with: 'Morning light'
    click_on 'Create a music style'

    assert_current_path new_music_style_preset_path
  end
end

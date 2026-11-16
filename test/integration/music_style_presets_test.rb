require 'test_helper'

class MusicStylePresetsTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @preset = @alice.music_style_presets.create!(name: 'Folk', description: 'Warm acoustic guitar')
    @other = users(:bob).music_style_presets.create!(name: 'Private jazz', description: 'Secret saxophone')
    sign_in_as @alice
  end

  test 'manages personal presets in settings' do
    get music_style_presets_path

    assert_response :success
    assert_select 'h2', text: 'Folk'
    assert_select 'h2', text: 'Private jazz', count: 0

    assert_difference('MusicStylePreset.count') do
      post music_style_presets_path, params: { music_style_preset: {
        name: 'Rock', description: 'Distorted guitars', user_id: users(:bob).id
      } }
    end
    assert_redirected_to music_style_presets_path
    assert_equal @alice, MusicStylePreset.find_by!(name: 'Rock').user

    patch music_style_preset_path(@preset), params: { music_style_preset: { description: 'Fingerpicked guitar' } }

    assert_equal 'Fingerpicked guitar', @preset.reload.description

    assert_difference('MusicStylePreset.count', -1) { delete music_style_preset_path(@preset) }
  end

  test 'rejects invalid and duplicate presets without losing the draft' do
    post music_style_presets_path, params: { music_style_preset: { name: 'Folk', description: 'New draft' } }

    assert_response :unprocessable_content
    assert_select 'textarea', text: 'New draft'

    patch music_style_preset_path(@preset), params: { music_style_preset: { description: '' } }

    assert_response :unprocessable_content
    assert_equal 'Warm acoustic guitar', @preset.reload.description
  end

  test 'cannot read edit or delete another users preset even as an admin' do
    [@alice, users(:admin)].each do |user|
      sign_in_as user
      get edit_music_style_preset_path(@other)

      assert_response :not_found
      patch music_style_preset_path(@other), params: { music_style_preset: { description: 'Changed' } }

      assert_response :not_found
      delete music_style_preset_path(@other)

      assert_response :not_found
    end
    assert_equal 'Secret saxophone', @other.reload.description
  end

  test 'audio studio offers only personal presets' do
    Workflow.create!(name: 'Music', kind: :audio, graph: {
                       '1' => { 'class_type' => 'Music',
                                'inputs' => { 'text' => '{{prompt}}', 'lyrics' => '{{lyrics}}' } }
                     })
    get audio_studio_path

    assert_response :success
    assert_select '#music_style_preset option', text: 'Folk'
    assert_select '#music_style_preset option', text: 'Private jazz', count: 0
  end

  test 'audio generations use the style as the prompt and keep lyrics separate' do
    workflow = Workflow.create!(name: 'Music', kind: :audio, graph: {
                                  '1' => { 'class_type' => 'Music',
                                           'inputs' => { 'text' => '{{prompt}}', 'lyrics' => '{{lyrics}}' } }
                                })
    post generations_path, params: { generation: {
      workflow_id: workflow.id, prompt: 'Guitar and flute', lyrics: 'Hello spring'
    } }

    assert_response :redirect
    song = @alice.generations.order(:created_at).last

    assert_equal 'Guitar and flute', song.prompt
    assert_equal 'Guitar and flute', song.placeholder_values.fetch('prompt')
    assert_equal 'Hello spring', song.lyrics
    @preset.destroy!

    assert_equal 'Guitar and flute', song.reload.prompt
    assert_equal 'Guitar and flute', song.reusable_attributes.fetch(:prompt)

    get generation_path(song)

    assert_response :success
    assert_select 'p', text: 'Guitar and flute'
  end

  test 'clearing a reused music style stays cleared when switching workflows' do
    workflow = Workflow.create!(name: 'Music', kind: :audio, graph: {
                                  '1' => { 'class_type' => 'Music', 'inputs' => { 'text' => '{{prompt}}' } }
                                })
    song = @alice.generations.create!(workflow: workflow, prompt: 'Folk')
    get audio_studio_path, params: { from: song.id, carry: { prompt: '' } }

    assert_response :success
    assert_select 'textarea[name="generation[prompt]"]', text: ''
  end

  test 'audio without saved styles offers creation and just style and lyrics inputs' do
    @preset.destroy!
    Workflow.create!(name: 'Music', kind: :audio, graph: {
                       '1' => { 'class_type' => 'Music',
                                'inputs' => { 'text' => '{{prompt}}', 'lyrics' => '{{lyrics}}' } }
                     })
    get audio_studio_path

    assert_response :success
    assert_select '#music_style_preset', count: 0
    assert_select 'a[href=?]', new_music_style_preset_path, text: 'Create a music style'
    assert_select 'textarea', count: 2
    assert_select 'label[for="generation_prompt"]', text: 'Music style'
    assert_select 'label', text: 'Describe what you want', count: 0
    assert_select '.card .h-section-label', text: 'Style'
  end

  test 'missing lyrics keeps the editable style when rendering audio errors' do
    workflow = Workflow.create!(name: 'Music', kind: :audio, graph: {
                                  '1' => { 'class_type' => 'Music',
                                           'inputs' => { 'text' => '{{prompt}}', 'lyrics' => '{{lyrics}}' } }
                                })
    post generations_path, params: { generation: { workflow_id: workflow.id, prompt: 'Bright folk', lyrics: '' } }

    assert_response :unprocessable_content
    assert_select 'textarea[name="generation[prompt]"]', text: 'Bright folk'
    assert_select 'textarea', count: 2
  end

  test 'requires sign in' do
    delete logout_path
    get music_style_presets_path

    assert_redirected_to login_path
  end
end

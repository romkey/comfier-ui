require 'test_helper'

class AlbumArtTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @workflow = Workflow.create!(
      name: 'ACE-Step', kind: 'audio',
      graph: { '1' => { 'class_type' => 'TextEncodeAceStepAudio',
                        'inputs' => { 'tags' => '{{prompt}}', 'lyrics' => '{{lyrics}}' } } }
    )
    lyrics = "[verse]\nNeon rain on empty streets\n\n[chorus]\nDrive all night"
    @audio = users(:alice).generations.create!(workflow: @workflow, prompt: 'dreamy synthwave. ', lyrics:)
    @audio.update!(status: :succeeded)
  end

  test 'fills the default template with the prompt and cleaned-up lyrics' do
    prompt = AlbumArt.new(@audio).prompt

    assert_includes prompt, 'described as: dreamy synthwave.'
    assert_includes prompt, 'lyrics: Neon rain on empty streets / Drive all night'
    assert_no_match(/\[verse\]|\{\{/, prompt)
  end

  test 'drops the lyrics section when the track has none' do
    @audio.lyrics = nil
    prompt = AlbumArt.new(@audio).prompt

    assert_includes prompt, 'dreamy synthwave'
    assert_not_includes prompt, 'lyrics'
    assert_no_match(/\n{3,}/, prompt)
  end

  test 'uses the admin template and leaves unknown tokens alone' do
    template = 'Cover for {{ prompt }}{{#lyrics}} about {{lyrics}}{{/lyrics}}, {{mood}}'
    app_settings(:default).update!(album_art_prompt: template)

    assert_equal 'Cover for dreamy synthwave about Neon rain on empty streets / Drive all night, {{mood}}',
                 AlbumArt.new(@audio).prompt
  end

  test 'shortens long lyrics' do
    @audio.lyrics = 'la ' * 1000

    assert_operator AlbumArt.new(@audio).values['lyrics'].length, :<=, AlbumArt::LYRICS_LIMIT
  end

  test 'uses the chosen image style, else the first one that works from a prompt' do
    assert_equal workflows(:sd_image), AlbumArt.workflow

    app_settings(:default).update!(album_art_workflow: workflows(:sdxl_image))

    assert_equal workflows(:sdxl_image), AlbumArt.workflow

    workflows(:sdxl_image).update!(enabled: false)

    assert_equal workflows(:sd_image), AlbumArt.workflow
  end

  test 'skips styles that need an uploaded image' do
    assert_not AlbumArt.usable_workflow?(workflows(:image_to_3d))
    graph = { '1' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => '{{image}}', 'text' => '{{prompt}}' } } }
    img2img = Workflow.create!(name: 'Img2img', kind: 'image', position: -1, graph:)

    assert_not AlbumArt.usable_workflow?(img2img)
    assert_equal workflows(:sd_image), AlbumArt.workflow
  end

  test 'is only offered for finished audio' do
    assert AlbumArt.available_for?(@audio)
    assert_not AlbumArt.available_for?(generations(:alice_done))

    @audio.status = :running

    assert_not AlbumArt.available_for?(@audio)
  end

  test 'queues a square image and points the track at it' do
    art = nil
    assert_enqueued_with(job: SubmitGenerationJob) { art = AlbumArt.new(@audio).create!(user: users(:alice)) }

    assert_predicate art, :image?
    assert_equal workflows(:sd_image), art.workflow
    assert_equal '1:1', art.aspect_ratio
    assert_includes art.prompt, 'dreamy synthwave'
    assert_equal art, @audio.reload.album_art_generation
    assert_predicate @audio, :album_art_in_progress?
    assert_nil @audio.album_art_image
  end

  test 'shows the first image once the art succeeds, and forgets it when the art is deleted' do
    art = AlbumArt.new(@audio).create!(user: users(:alice))
    art.outputs.attach(io: file_fixture('pixel.png').open, filename: 'cover.png', content_type: 'image/png')
    art.succeed!

    assert_equal 'cover.png', @audio.reload.album_art_image.filename.to_s

    art.destroy!

    assert_nil @audio.reload.album_art_generation_id
  end
end

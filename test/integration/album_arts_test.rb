require 'test_helper'

class AlbumArtsTest < ActionDispatch::IntegrationTest
  setup do
    workflow = Workflow.create!(
      name: 'ACE-Step', kind: 'audio',
      graph: { '1' => { 'class_type' => 'TextEncodeAceStepAudio',
                        'inputs' => { 'tags' => '{{prompt}}', 'lyrics' => '{{lyrics}}' } } }
    )
    @audio = users(:alice).generations.create!(workflow:, prompt: 'dreamy synthwave', lyrics: 'Neon rain')
    @audio.outputs.attach(io: StringIO.new('ID3'), filename: 'song.mp3', content_type: 'audio/mpeg')
    @audio.update!(status: :succeeded)
    sign_in_as users(:alice)
  end

  test 'finished audio offers to create album art' do
    get generation_path(@audio)

    assert_select "form[action='#{generation_album_art_path(@audio)}'] button", text: /Create album art/
    assert_select '.output-audio-cover', count: 0
  end

  test 'other results do not offer album art' do
    get generation_path(generations(:alice_done))

    assert_select "form[action$='/album_art']", count: 0
  end

  test 'no button when no image style can make it' do
    Workflow.where(kind: 'image').find_each { it.update!(enabled: false) }
    get generation_path(@audio)

    assert_select "form[action='#{generation_album_art_path(@audio)}']", count: 0
  end

  test 'queues the art and shows its progress' do
    assert_difference -> { users(:alice).generations.where(kind: 'image').count } do
      assert_enqueued_with(job: SubmitGenerationJob) { post generation_album_art_path(@audio) }
    end

    assert_redirected_to generation_path(@audio)
    art = @audio.reload.album_art_generation

    assert_includes art.prompt, 'dreamy synthwave'
    assert_includes art.prompt, 'Neon rain'

    follow_redirect!

    assert_select 'button[disabled]', text: /Creating album art/
    assert_select "a[href='#{generation_path(art)}']", text: 'Open image result'
  end

  test 'one cover at a time' do
    AlbumArt.new(@audio).create!(user: users(:alice))

    assert_no_difference -> { Generation.count } do
      post generation_album_art_path(@audio)
    end
    assert_equal 'Album art is already being created.', flash[:alert]
  end

  test 'the player shows the finished cover' do
    finish_art

    get generation_path(@audio)

    assert_select '.output-audio img.output-audio-cover'
    assert_select '.output-audio audio'
    assert_select "form[action='#{generation_album_art_path(@audio)}'] button", text: /New album art/

    get generations_path(kind: 'audio')

    assert_select "#results_generations ##{ActionView::RecordIdentifier.dom_id(@audio)} .output-audio-cover"
  end

  test 'public links serve the cover' do
    finish_art
    @audio.create_public_link!

    get public_share_path(@audio.public_token)

    assert_select "img.output-audio-cover[src='#{public_share_cover_path(@audio.public_token)}']"

    get public_share_cover_path(@audio.public_token)

    assert_response :success
    assert_equal 'image/png', response.media_type
  end

  test 'public cover is missing without art' do
    @audio.create_public_link!

    get public_share_cover_path(@audio.public_token)

    assert_response :not_found
  end

  test 'cannot create art for someone else\'s audio' do
    sign_in_as users(:bob)

    post generation_album_art_path(@audio)

    assert_response :not_found
  end

  test 'refuses audio that has not finished' do
    @audio.update!(status: :failed)

    assert_no_difference -> { Generation.count } do
      post generation_album_art_path(@audio)
    end
    assert_equal 'Album art is only for finished audio.', flash[:alert]
  end

  private

  def finish_art
    art = AlbumArt.new(@audio).create!(user: users(:alice))
    art.outputs.attach(io: file_fixture('pixel.png').open, filename: 'cover.png', content_type: 'image/png')
    art.succeed!
    art
  end
end

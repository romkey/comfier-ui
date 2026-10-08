require 'test_helper'

class PublicSharesTest < ActionDispatch::IntegrationTest
  setup do
    @generation = generations(:alice_done)
    @generation.update!(status: :succeeded)
    unless @generation.outputs.attached?
      @generation.outputs.attach(io: file_fixture('pixel.png').open, filename: 'out.png', content_type: 'image/png')
    end
    @generation.create_public_link!
    @token = @generation.public_token
  end

  test 'anyone can view a public link without signing in' do
    get public_share_path(@token)

    assert_response :success
    assert_select 'h1', text: 'Shared result'
    assert_no_match(/lighthouse at dusk/i, response.body)
  end

  test 'revoked or rotated tokens return not found' do
    get public_share_path(@token)

    assert_response :success

    @generation.revoke_public_link!

    get public_share_path(@token)

    assert_response :not_found

    @generation.create_public_link!
    old = @token
    @generation.create_public_link!

    get public_share_path(old)

    assert_response :not_found
  end

  test 'only the owner can create a public link' do
    sign_in_as users(:bob)

    post public_link_generation_path(@generation)

    assert_response :not_found
  end

  test 'owner can create change and revoke a public link' do
    sign_in_as users(:alice)
    @generation.revoke_public_link!

    post public_link_generation_path(@generation)

    assert_redirected_to generation_path(@generation)
    assert_predicate @generation.reload, :publicly_linked?

    old = @generation.public_token
    post public_link_generation_path(@generation)

    assert_not_equal old, @generation.reload.public_token

    delete public_link_generation_path(@generation)

    assert_redirected_to generation_path(@generation)
    assert_not @generation.reload.publicly_linked?
  end

  test 'running generations cannot get a public link' do
    sign_in_as users(:alice)
    running = generations(:alice_running)

    post public_link_generation_path(running)

    assert_response :unprocessable_content
  end

  test 'media route requires a valid token' do
    get public_share_output_path(@token, 0)

    assert_response :success

    @generation.revoke_public_link!

    get public_share_output_path(@token, 0)

    assert_response :not_found
  end

  test 'shared video output supports byte ranges for playback' do
    @generation.outputs.purge
    @generation.outputs.attach(
      io: StringIO.new('0123456789'),
      filename: 'clip.mp4',
      content_type: 'video/mp4'
    )

    get public_share_output_path(@token, 0), headers: { 'Range' => 'bytes=0-4' }

    assert_response :partial_content
    assert_equal 'bytes', response.headers['Accept-Ranges']
    assert_equal 'bytes 0-4/10', response.headers['Content-Range']
    assert_equal '5', response.headers['Content-Length']
    assert_equal '01234', response.body
  end

  test 'image links unfurl with the image as their preview' do
    get public_share_path(@token)

    assert_select 'meta[property="og:title"][content="Shared result"]'
    assert_select 'meta[property="og:url"][content=?]', public_share_url(@token)
    assert_select 'meta[property="og:image"][content=?]', public_share_output_url(@token, 0)
    assert_select 'meta[property="twitter:card"][content="summary_large_image"]'
    assert_select 'meta[property="og:description"]' do |tags|
      assert_no_match(/lighthouse at dusk/i, tags.first['content'])
    end
  end

  test 'video links unfurl as playable video with the poster as their preview' do
    @generation.outputs.purge
    @generation.outputs.attach(io: StringIO.new('0123456789'), filename: 'clip.mp4', content_type: 'video/mp4')
    @generation.output_poster.attach(io: file_fixture('pixel.png').open, filename: 'poster.png',
                                     content_type: 'image/png')

    get public_share_path(@token)

    assert_select 'meta[property="og:type"][content="video.other"]'
    assert_select 'meta[property="og:video"][content=?]', public_share_output_url(@token, 0)
    assert_select 'meta[property="og:video:type"][content="video/mp4"]'
    assert_select 'meta[property="og:image"][content=?]', public_share_poster_url(@token)

    get public_share_poster_url(@token)

    assert_response :success
    assert_equal 'image/png', response.media_type
  end

  test 'poster route requires a valid token and a poster' do
    get public_share_poster_path(@token)

    assert_response :not_found

    @generation.output_poster.attach(io: file_fixture('pixel.png').open, filename: 'poster.png',
                                     content_type: 'image/png')
    @generation.revoke_public_link!

    get public_share_poster_path(@token)

    assert_response :not_found
  end
end

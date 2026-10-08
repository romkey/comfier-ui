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

  BROWSER = { 'User-Agent' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 Safari/605.1' }.freeze

  test 'views from people opening the link are counted' do
    freeze_time do
      2.times { get public_share_path(@token), headers: BROWSER }

      @generation.reload

      assert_equal 2, @generation.public_view_count
      assert_equal Time.current, @generation.public_last_viewed_at
    end
  end

  test 'preview fetchers, prefetches, the owner, and admins are not counted' do
    ['Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)',
     'Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)',
     'facebookexternalhit/1.1 Facebot Twitterbot/1.0',
     'TelegramBot (like TwitterBot)', 'curl/8.7.1', ''].each do |agent|
      get public_share_path(@token), headers: { 'User-Agent' => agent }
    end
    get public_share_path(@token), headers: BROWSER.merge('Sec-Purpose' => 'prefetch')

    sign_in_as users(:alice)
    get public_share_path(@token), headers: BROWSER
    sign_in_as users(:admin)
    get public_share_path(@token), headers: BROWSER

    assert_equal 0, @generation.reload.public_view_count
  end

  test 'media requests are not counted as views' do
    get public_share_output_path(@token, 0), headers: BROWSER

    assert_equal 0, @generation.reload.public_view_count
  end

  test 'a new or revoked link starts counting from zero' do
    get public_share_path(@token), headers: BROWSER

    assert_equal 1, @generation.reload.public_view_count

    @generation.create_public_link!

    assert_equal 0, @generation.public_view_count
    assert_nil @generation.public_last_viewed_at

    get public_share_path(@generation.public_token), headers: BROWSER
    @generation.reload.revoke_public_link!

    assert_equal 0, @generation.public_view_count
  end

  test 'the owner sees the view count on the result page' do
    @generation.update!(public_view_count: 3, public_last_viewed_at: Time.current)
    sign_in_as users(:alice)

    get generation_path(@generation)

    assert_select '.public-link-controls', text: /3 views/
  end
end

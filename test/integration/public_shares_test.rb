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
     'TelegramBot (like TwitterBot)', 'curl/8.7.1', 'WhatsApp/2.23.20.0 A', 'WhatsApp/2.2329.9 i',
     'Mozilla/5.0 (Windows NT 6.1; WOW64) SkypeUriPreview Preview/0.5',
     'Pinterest/0.2 (+https://www.pinterest.com/bot.html)',
     'Mozilla/5.0 (compatible; Pinterestbot/1.0; +http://www.pinterest.com/bot.html)', ''].each do |agent|
      get public_share_path(@token), headers: { 'User-Agent' => agent }
    end
    get public_share_path(@token), headers: BROWSER.merge('Sec-Purpose' => 'prefetch')

    sign_in_as users(:alice)
    get public_share_path(@token), headers: BROWSER
    sign_in_as users(:admin)
    get public_share_path(@token), headers: BROWSER

    assert_equal 0, @generation.reload.public_view_count
  end

  test 'views in apps\' in-app browsers are counted' do
    ['Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A; wv) AppleWebKit/537.36 (KHTML, like Gecko) ' \
     'Version/4.0 Chrome/129.0.6668.81 Mobile Safari/537.36 WhatsApp/2.24.20.89',
     'Mozilla/5.0 (Linux; Android 14; SM-S921B Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) ' \
     'Version/4.0 Chrome/129.0.6668.81 Mobile Safari/537.36 [Pinterest/Android]',
     'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) ' \
     'Mobile/15E148 [Pinterest/iOS]',
     'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 ' \
     'Safari/537.36 Skype/8.130'].each do |agent|
      get public_share_path(@token), headers: { 'User-Agent' => agent }
    end

    assert_equal 4, @generation.reload.public_view_count
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
    assert_select 'meta[property="og:image"][content=?]',
                  public_share_poster_url(@token, v: @generation.output_poster.blob_id)

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

  test 'a signed-out visitor gets the video poster from the public link, versioned by its file' do
    @generation.update!(kind: 'video')
    @generation.outputs.purge
    @generation.outputs.attach(io: StringIO.new('0123456789'), filename: 'clip.mp4', content_type: 'video/mp4',
                               identify: false)
    @generation.output_poster.attach(io: file_fixture('pixel.png').open, filename: 'poster.png',
                                     content_type: 'image/png')
    poster = public_share_poster_path(@token, v: @generation.output_poster.blob_id)

    get public_share_path(@token)

    assert_select "video[poster='#{poster}']"
    assert_select "meta[property='og:image'][content$='#{poster}']"

    get poster

    assert_response :success
  end
end

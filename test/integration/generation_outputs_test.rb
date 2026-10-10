require 'test_helper'

# Result files come from GenerationOutputsController at URLs that don't expire, with byte ranges for video.
class GenerationOutputsTest < ActionDispatch::IntegrationTest
  BYTES = '0123456789'.b

  setup do
    @generation = generations(:alice_done)
    @generation.update!(kind: 'video')
    @generation.outputs.attach(io: StringIO.new(BYTES), filename: 'clip.mp4', content_type: 'video/mp4',
                               identify: false)
    @output = @generation.outputs.last
    @path = output_generation_path(@generation, @output.id, filename: 'clip.mp4')
    @src = output_generation_path(@generation, @output.id, filename: 'clip.mp4', v: @output.blob_id)
  end

  test 'the owner gets the whole file with headers a video player needs' do
    sign_in_as users(:alice)

    get @path

    assert_response :success
    assert_equal BYTES, response.body
    assert_equal 'video/mp4', response.media_type
    assert_equal 'bytes', response.headers['Accept-Ranges']
    assert_equal '10', response.headers['Content-Length']
  end

  test 'files are inline, not sniffed, and cached privately' do
    sign_in_as users(:alice)

    get @path

    assert_equal 'nosniff', response.headers['X-Content-Type-Options']
    assert_match(/\Ainline/, response.headers['Content-Disposition'])
    assert_match(/private/, response.headers['Cache-Control'])
    assert_predicate response.headers['ETag'], :present?
  end

  test 'byte ranges, including the probes Safari and moov-at-the-end files make' do
    sign_in_as users(:alice)

    get @path, headers: { 'Range' => 'bytes=0-1' }

    assert_response :partial_content
    assert_equal 'bytes 0-1/10', response.headers['Content-Range']
    assert_equal '01', response.body

    get @path, headers: { 'Range' => 'bytes=4-' }

    assert_response :partial_content
    assert_equal '456789', response.body
  end

  test 'suffix and unsatisfiable ranges' do
    sign_in_as users(:alice)

    get @path, headers: { 'Range' => 'bytes=-3' }

    assert_response :partial_content
    assert_equal 'bytes 7-9/10', response.headers['Content-Range']
    assert_equal '789', response.body

    get @path, headers: { 'Range' => 'bytes=50-' }

    assert_response :range_not_satisfiable
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'a repeat request with the ETag is not modified, and HEAD has no body' do
    sign_in_as users(:alice)
    get @path
    etag = response.headers['ETag']

    get @path, headers: { 'If-None-Match' => etag }

    assert_response :not_modified

    head @path

    assert_response :success
    assert_equal '10', response.headers['Content-Length']
    assert_empty response.body
  end

  test 'download asks the browser to save the file' do
    sign_in_as users(:alice)

    get output_generation_path(@generation, @output.id, filename: 'clip.mp4', download: 1)

    assert_match(/\Aattachment/, response.headers['Content-Disposition'])
  end

  test 'the URL keeps working long after the page was rendered' do
    sign_in_as users(:alice)

    travel 2.days do
      get @path, headers: { 'Range' => 'bytes=0-1' }

      assert_response :partial_content
    end
  end

  test 'other members can not fetch an unshared result, and signed-out visitors are sent to log in' do
    sign_in_as users(:bob)

    get @path

    assert_response :not_found

    delete logout_path
    get @path

    assert_redirected_to login_path
  end

  test 'members can fetch a shared result until it is unshared or hidden for review' do
    @generation.share!
    sign_in_as users(:bob)

    get @path

    assert_response :success

    @generation.update!(hidden_for_review_at: Time.current)
    get @path

    assert_response :not_found
  end

  test 'admins can fetch any result' do
    sign_in_as users(:admin)

    get @path

    assert_response :success
  end

  test 'one result can not serve another result\'s file' do
    bob = generations(:bob_done)
    sign_in_as users(:alice)

    get output_generation_path(bob, @output.id, filename: 'clip.mp4')

    assert_response :not_found

    get output_generation_path(@generation, ActiveStorage::Attachment.maximum(:id) + 1)

    assert_response :not_found
  end

  test 'poster, cover, and reference image' do
    @generation.output_poster.attach(io: file_fixture('pixel.png').open, filename: 'poster.png',
                                     content_type: 'image/png')
    @generation.input_image.attach(io: file_fixture('pixel.png').open, filename: 'in.png', content_type: 'image/png')
    sign_in_as users(:alice)

    get poster_generation_path(@generation)

    assert_response :success
    assert_equal 'image/png', response.media_type

    get input_image_generation_path(@generation)

    assert_response :success

    get cover_generation_path(@generation)

    assert_response :not_found
  end

  test 'result pages link files through the output route, never Active Storage\'s expiring URLs' do
    @generation.output_poster.attach(io: file_fixture('pixel.png').open, filename: 'poster.png',
                                     content_type: 'image/png')
    @generation.share!
    sign_in_as users(:alice)

    get generation_path(@generation)

    assert_select "video[src='#{@src}']"
    assert_no_match %r{/rails/active_storage/}, response.body

    get generations_path

    assert_no_match %r{/rails/active_storage/}, response.body

    get shared_path(@generation)

    assert_select "video[src='#{@src}']"
    assert_no_match %r{/rails/active_storage/}, response.body
  end
end

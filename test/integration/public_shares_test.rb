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

    assert_response :redirect

    @generation.revoke_public_link!

    get public_share_output_path(@token, 0)

    assert_response :not_found
  end
end

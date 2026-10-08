require 'test_helper'

module Admin
  class PublicLinksTest < ActionDispatch::IntegrationTest
    setup do
      @generation = generations(:bob_done)
      @generation.update!(status: :succeeded)
      @generation.create_public_link!
      @generation.update!(public_view_count: 7, public_last_viewed_at: Time.current)
    end

    test 'non-admins cannot see every public link' do
      sign_in_as users(:alice)

      get admin_public_links_path

      assert_response :not_found
    end

    test 'admins see every public link with its owner and views' do
      sign_in_as users(:admin)

      get admin_public_links_path

      assert_response :success
      assert_select 'td', text: @generation.user.display_name
      assert_select 'td.num', text: '7'
      assert_select 'a[href=?]', public_share_path(@generation.public_token)
    end
  end
end

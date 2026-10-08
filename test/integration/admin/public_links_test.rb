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
      assert_select 'th .table-sort-link.active', text: /Shared/
    end

    test 'column headers sort the list and keep the type filter' do
      video = link(:alice_failed, views: 40, shared_at: 3.days.ago)
      image = link(:alice_done, views: 2, shared_at: 1.day.ago, viewed_at: nil)
      sign_in_as users(:admin)

      get admin_public_links_path(sort: 'views', dir: 'desc')

      assert_equal [video, @generation, image].map(&:public_token), listed_tokens
      assert_select 'th .table-sort-link.active', text: /Views/

      get admin_public_links_path(sort: 'last_viewed', dir: 'asc')

      assert_equal image.public_token, listed_tokens.first

      get admin_public_links_path(kind: 'image', sort: 'views', dir: 'asc')

      assert_equal [image, @generation].map(&:public_token), listed_tokens
      assert_select 'th a.table-sort-link[href*="kind=image"]', count: 6
    end

    test 'type pills filter the list and show counts' do
      video = link(:alice_failed, views: 1, shared_at: 1.day.ago)
      sign_in_as users(:admin)

      get admin_public_links_path(kind: 'video')

      assert_equal [video.public_token], listed_tokens
      assert_select '.filter-chip.active', text: /Video\s*1/
      assert_select '.filter-chip', text: /All\s*2/
    end

    test 'ignores unknown sort and filter parameters' do
      sign_in_as users(:admin)

      get admin_public_links_path(sort: 'invalid', dir: 'sideways', kind: 'nope')

      assert_response :success
      assert_select 'th .table-sort-link.active', text: /Shared/
      assert_select '.filter-chip.active', text: /All/
    end

    private

    def link(name, views:, shared_at:, viewed_at: Time.current)
      generation = generations(name)
      generation.update!(status: :succeeded)
      generation.create_public_link!
      generation.update!(public_view_count: views, public_shared_at: shared_at, public_last_viewed_at: viewed_at)
      generation
    end

    def listed_tokens
      css_select('tbody td a').map { it['href'].delete_prefix('/p/') }
    end
  end
end

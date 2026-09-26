require 'test_helper'

module Admin
  class UsersTest < ActionDispatch::IntegrationTest
    test 'non-admins cannot see users' do
      sign_in_as users(:alice)

      get admin_users_path

      assert_response :not_found
    end

    test 'lists users with login, join date, role, and generation counts' do
      sign_in_as users(:admin)
      users(:alice).update!(last_signed_in_at: 2.hours.ago)
      users(:bob).update!(last_signed_in_at: 1.day.ago, created_at: 30.days.ago)

      get admin_users_path

      assert_response :success
      assert_select 'h1', text: 'Users'
      assert_select 'td', text: /Alice Artist/
      assert_select 'td', text: /Bob Builder/
      assert_select '.badge', text: 'Admin'
      assert_select '.settings-nav-item.active', text: /Users/
    end

    test 'column headers sort the list' do
      sign_in_as users(:admin)

      get admin_users_path(sort: 'generations', dir: 'desc')

      assert_response :success
      assert_select 'th .table-sort-link.active', text: /Generations/
      assert_match(/Alice Artist/, css_select('tbody tr').first.text)

      get admin_users_path(sort: 'user', dir: 'asc')

      assert_response :success
      names = css_select('tbody tr td:first-child .fw-medium').map(&:text)

      assert_equal names.sort, names
    end

    test 'ignores unknown sort parameters' do
      sign_in_as users(:admin)

      get admin_users_path(sort: 'invalid', dir: 'sideways')

      assert_response :success
      assert_select 'th .table-sort-link.active', text: /Last login/
    end
  end
end

require 'test_helper'

module Admin
  class BackendsTest < ActionDispatch::IntegrationTest
    setup do
      @backend = backends(:gpu)
    end

    test 'non-admins cannot see the admin area' do
      sign_in_as users(:alice)

      get admin_backends_path

      assert_response :not_found
      post admin_backends_path, params: { backend: { name: 'Sneaky', base_url: 'http://x.test' } }

      assert_response :not_found
      assert_nil Backend.find_by(name: 'Sneaky')
    end

    test 'lists backends with their status' do
      sign_in_as users(:admin)
      @backend.update!(last_check_ok: false, last_check_message: 'refused')

      get admin_backends_path

      assert_response :success
      assert_select 'td', text: /GPU box/
      assert_select '.badge', text: 'Unreachable'
      assert_select '.badge', text: 'Disabled'
      assert_select '.settings-nav-item.attention', text: /Unreachable backends/
    end

    test 'adding a backend checks the connection' do
      sign_in_as users(:admin)
      stub_request(:get, 'http://new.test:8188/system_stats')
        .to_return(body: { system: { comfyui_version: '0.3.62' }, devices: [] }.to_json)
      stub_inventory(Backend.new(base_url: 'http://new.test:8188'), downloader: true)

      post admin_backends_path, params: { backend: { name: 'New', base_url: 'http://new.test:8188/', enabled: '1' } }

      assert_redirected_to admin_backends_path
      assert_match(/New is reachable: ComfyUI 0.3.62/, flash[:notice])
      assert Backend.find_by!(name: 'New').last_check_ok
      follow_redirect!

      assert_select 'td', text: /Model downloads: Comfier downloader node/
    end

    test 'invalid backends re-render the form' do
      sign_in_as users(:admin)

      post admin_backends_path, params: { backend: { name: '', base_url: 'nope' } }

      assert_response :unprocessable_content
      assert_select '.alert-danger'
    end

    test 'a blank token on edit keeps the saved one' do
      sign_in_as users(:admin)
      @backend.update!(auth_token: 'keep-me')

      patch admin_backend_path(@backend), params: { backend: { name: 'Renamed', auth_token: '' } }

      assert_redirected_to admin_backends_path
      assert_equal 'Renamed', @backend.reload.name
      assert_equal 'keep-me', @backend.auth_token
    end

    test 'the saved token can be replaced or cleared' do
      sign_in_as users(:admin)
      @backend.update!(auth_token: 'old')

      patch admin_backend_path(@backend), params: { backend: { auth_token: 'new' } }

      assert_equal 'new', @backend.reload.auth_token

      patch admin_backend_path(@backend), params: { backend: { auth_token: '', clear_auth_token: '1' } }

      assert_nil @backend.reload.auth_token
    end

    test 'the edit form never reveals the token' do
      sign_in_as users(:admin)
      @backend.update!(auth_token: 'super-secret')

      get edit_admin_backend_path(@backend)

      assert_response :success
      assert_not_includes response.body, 'super-secret'
    end

    test 'test connection' do
      sign_in_as users(:admin)
      stub_request(:get, comfy_url(@backend, 'system_stats')).to_raise(Errno::ECONNREFUSED)

      post check_admin_backend_path(@backend)

      assert_redirected_to admin_backends_path
      assert_match(/could not be reached/, flash[:notice])
      assert_predicate @backend.reload, :unhealthy?
    end

    test 'removing a backend' do
      sign_in_as users(:admin)

      assert_difference('Backend.count', -1) { delete admin_backend_path(@backend) }
      assert_redirected_to admin_backends_path
    end

    test 'the Sidekiq dashboard is hidden from non-admins' do
      get '/admin/sidekiq'

      assert_response :not_found

      sign_in_as users(:alice)
      get '/admin/sidekiq'

      assert_response :not_found
    end
  end
end

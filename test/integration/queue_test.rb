require 'test_helper'

class QueueTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:alice) }

  test 'the queue page lists in-progress jobs' do
    get queue_path

    assert_response :success
    assert_select 'h1', text: 'Queue'
    assert_match(/SD 1\.5/, response.body)
    assert_match(/You/, response.body)
    assert_select 'button', text: /Cancel/
  end

  test 'the navbar includes queue and shared links' do
    get image_studio_path

    assert_select 'a.nav-link', text: /Queue/
    assert_select 'a.nav-link', text: 'Shared'
  end
end

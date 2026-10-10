require 'test_helper'

class MediaErrorsTest < ActionDispatch::IntegrationTest
  test 'a failed video is logged with what the browser said' do
    sign_in_as users(:alice)
    generation = generations(:alice_done)

    assert_difference -> { ActivityLog.media_failed.count }, 1 do
      post media_errors_path, params: { code: '2', network_state: 2, ready_state: 0, src: '/results/1/outputs/2/a.mp4',
                                        generation_id: generation.id, page: '/results/1', extra: 'ignored' },
                              as: :json
    end

    assert_response :no_content
    log = ActivityLog.media_failed.last

    assert_equal [users(:alice), generation], [log.user, log.subject]
    assert_match(/failed \(2\)/, log.message)
    assert_equal '2', log.details['code']
    assert_not log.details.key?('extra')
  end

  test 'public link viewers can report without signing in or a CSRF token' do
    post media_errors_path, params: { code: 'stalled', src: '/p/tok/outputs/0', page: 'public link' }, as: :json

    assert_response :no_content
    assert_match(/never started/, ActivityLog.media_failed.last.message)
  end
end

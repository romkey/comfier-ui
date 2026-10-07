require 'test_helper'

class VideoScriptsTest < ActionDispatch::IntegrationTest
  setup do
    @previous = {
      'LITELLM_URL' => ENV.fetch('LITELLM_URL', nil),
      'LITELLM_MODEL' => ENV.fetch('LITELLM_MODEL', nil)
    }
    ENV['LITELLM_URL'] = 'http://litellm.test'
    ENV['LITELLM_MODEL'] = 'gpt-test'
    stub_request(:get, 'http://litellm.test/v1/models').to_return(body: { data: [{ id: 'gpt-test' }] }.to_json)
    sign_in_as users(:alice)
  end

  teardown do
    @previous.each { |key, value| ENV[key] = value }
  end

  test 'the video page offers to write a script without leaving the page' do
    get '/video'

    assert_select "[data-controller='video-script'][data-video-script-url-value='#{video_scripts_path}']" do
      assert_select 'textarea[data-video-script-target=prompt]'
      assert_select 'button[type=button][data-action="video-script#start"]', text: /Write a script/
      assert_select 'button[type=button][data-action="video-script#cancel"]', text: 'Cancel'
    end
  end

  test 'the image page does not offer a script' do
    get '/image'

    assert_select "[data-controller='video-script']", count: 0
  end

  test 'no script button without LiteLLM' do
    ENV['LITELLM_URL'] = nil
    get '/video'

    assert_select "[data-controller='video-script']", count: 0
  end

  test 'starts a script request and queues the job' do
    assert_no_difference -> { ChatConversation.count } do # the chat sidebar is untouched
      assert_enqueued_with(job: VideoScriptJob) do
        post video_scripts_path, params: script_params(prompt: 'a lighthouse at dusk', duration: '6'), as: :json
      end
    end

    assert_response :created
    script_request = users(:alice).video_script_requests.last

    assert_equal({ 'id' => script_request.id, 'status' => 'pending', 'script' => nil, 'error' => nil },
                 response.parsed_body)
    assert_includes script_request.message, 'a lighthouse at dusk'
    assert_includes script_request.message, '6 seconds long'
  end

  test 'asks for a description first' do
    assert_no_difference -> { VideoScriptRequest.count } do
      post video_scripts_path, params: script_params(prompt: ' '), as: :json
    end

    assert_response :unprocessable_content
    assert_equal 'Describe the video first, then ask for a script.', response.parsed_body['error']
  end

  test 'refuses when chat is not configured' do
    ENV['LITELLM_URL'] = nil

    assert_no_difference -> { VideoScriptRequest.count } do
      post video_scripts_path, params: script_params, as: :json
    end

    assert_response :service_unavailable
  end

  test 'reports progress and the finished script' do
    script_request = users(:alice).video_script_requests.create!(message: 'm', status: :succeeded, script: 'Shot one.')

    get video_script_path(script_request), as: :json

    assert_equal 'succeeded', response.parsed_body['status']
    assert_equal 'Shot one.', response.parsed_body['script']
  end

  test 'cancels a running request' do
    script_request = users(:alice).video_script_requests.create!(message: 'm', status: :retrying)

    delete video_script_path(script_request), as: :json

    assert_predicate script_request.reload, :cancelled?
  end

  test 'cancelling a finished request leaves it alone' do
    script_request = users(:alice).video_script_requests.create!(message: 'm', status: :succeeded, script: 'Done.')

    delete video_script_path(script_request), as: :json

    assert_predicate script_request.reload, :succeeded?
  end

  test 'members only see their own requests' do
    script_request = users(:bob).video_script_requests.create!(message: 'm')

    get video_script_path(script_request), as: :json

    assert_response :not_found
  end

  test 'starting a request clears out old ones' do
    old = users(:alice).video_script_requests.create!(message: 'm', created_at: 2.days.ago)

    post video_scripts_path, params: script_params, as: :json

    assert_not VideoScriptRequest.exists?(old.id)
  end

  test 'the request works with forgery protection on' do
    with_forgery_protection do
      get '/video'
      token = css_select('meta[name=csrf-token]').first['content']

      post video_scripts_path, params: script_params, headers: { 'X-CSRF-Token' => token }, as: :json

      assert_response :created
    end
  end

  private

  def script_params(prompt: 'waves', duration: '5')
    { generation: { workflow_id: workflows(:wan_video).id, prompt:, aspect_ratio: '16:9', duration: } }
  end

  def with_forgery_protection
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end

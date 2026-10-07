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

  test 'the video page offers to write a script' do
    get '/video'

    assert_select "button[formaction='#{video_script_path}']", text: /Write a script/
  end

  test 'the image page does not offer a script' do
    get '/image'

    assert_select "button[formaction='#{video_script_path}']", count: 0
  end

  test 'no script button without LiteLLM' do
    ENV['LITELLM_URL'] = nil
    get '/video'

    assert_select "button[formaction='#{video_script_path}']", count: 0
  end

  test 'starts a chat with the script request and queues a reply' do
    assert_difference -> { users(:alice).chat_conversations.count } do
      assert_enqueued_with(job: ChatReplyJob) do
        post video_script_path, params: { generation: {
          workflow_id: workflows(:wan_video).id, prompt: 'a lighthouse at dusk', aspect_ratio: '16:9', duration: '6'
        } }
      end
    end

    conversation = users(:alice).chat_conversations.recent_first.first

    assert_redirected_to chat_path(conversation)
    assert_equal 'Video script: a lighthouse at dusk', conversation.title
    request_message, reply = conversation.chat_messages.to_a

    assert_predicate request_message, :user?
    assert_includes request_message.content, 'a lighthouse at dusk'
    assert_includes request_message.content, '6 seconds long'
    assert_predicate reply, :pending?
  end

  test 'asks for a description first' do
    assert_no_difference -> { ChatConversation.count } do
      post video_script_path, params: { generation: { workflow_id: workflows(:wan_video).id, prompt: ' ' } }
    end

    assert_redirected_to video_studio_path(workflow_id: workflows(:wan_video).id)
    assert_equal 'Describe the video first, then ask for a script.', flash[:alert]
  end

  test 'refuses when chat is not configured' do
    ENV['LITELLM_URL'] = nil

    assert_no_difference -> { ChatConversation.count } do
      post video_script_path, params: { generation: { workflow_id: workflows(:wan_video).id, prompt: 'waves' } }
    end

    assert_redirected_to video_studio_path
  end
end

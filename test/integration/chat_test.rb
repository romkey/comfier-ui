require 'test_helper'

class ChatTest < ActionDispatch::IntegrationTest
  setup do
    @previous = {
      'LITELLM_URL' => ENV.fetch('LITELLM_URL', nil),
      'LITELLM_MODEL' => ENV.fetch('LITELLM_MODEL', nil)
    }
    ENV['LITELLM_URL'] = 'http://litellm.test'
    ENV['LITELLM_MODEL'] = 'gpt-test'
    stub_request(:get, 'http://litellm.test/v1/models')
      .to_return(body: { data: [{ id: 'gpt-test' }, { id: 'vision-model' }] }.to_json)
  end

  teardown do
    @previous.each { |key, value| ENV[key] = value }
  end

  test 'chat nav appears when LiteLLM is configured' do
    sign_in_as users(:alice)
    get image_studio_path

    assert_response :success
    assert_select 'a.nav-link', text: /Chat/
  end

  test 'members only see their own conversations' do
    sign_in_as users(:alice)
    get chat_path(chat_conversations(:bob_chat))

    assert_response :not_found
  end

  test 'shows admin notice on chat when configured' do
    app_settings(:default).update!(chat_notice_text: 'Use the main bot', chat_notice_url: 'https://chat.example.com')
    sign_in_as users(:alice)

    get chat_path(chat_conversations(:alice_chat))

    assert_response :success
    assert_select '.status-panel', text: /Use the main bot/
    assert_select "a[href=?][data-turbo='false']", chat_notice_link_path
  end

  test 'chat notice link redirects to configured URL when valid' do
    app_settings(:default).update!(chat_notice_url: 'https://chat.example.com')
    sign_in_as users(:alice)

    get chat_notice_link_path

    assert_redirected_to 'https://chat.example.com'
  end

  test 'creating a message enqueues a reply job' do
    sign_in_as users(:alice)
    conversation = chat_conversations(:alice_chat)

    assert_enqueued_with(job: ChatReplyJob) do
      post chat_messages_path(conversation),
           params: { chat_message: { content: 'Hi', model: 'gpt-test' } },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html, text/html' }
    end

    assert_response :success
    assert_match(/id="chat_composer"/, @response.body)
    assert_match(/disabled="disabled"/, @response.body)
  end

  test 'unconfigured LiteLLM shows a calm unavailable page' do
    ENV['LITELLM_URL'] = ''
    sign_in_as users(:alice)

    get chats_path

    assert_response :success
    assert_select '.status-panel', text: /isn't available yet/
  end
end

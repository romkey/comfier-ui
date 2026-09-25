require 'test_helper'

class SlackNotifierTest < ActiveSupport::TestCase
  API = 'https://slack.com/api/'.freeze

  setup do
    @generation = generations(:alice_done)
    @generation.outputs.attach(io: file_fixture('pixel.png').open, filename: 'out.png', content_type: 'image/png')
    @user = @generation.user
    @user.update!(slack_uid: 'U123', notify_slack: true)
    stub_request(:post, "#{API}conversations.open")
      .with(body: { users: 'U123' }, headers: { 'Authorization' => 'Bearer xoxb-test' })
      .to_return(body: { ok: true, channel: { id: 'D999' } }.to_json)
  end

  test 'sends a direct message with a link' do
    post_message = stub_request(:post, "#{API}chat.postMessage")
                   .with { |request| request.body.include?('channel=D999') && request.body.include?('is+ready') }
                   .to_return(body: { ok: true }.to_json)

    with_notifications_configured { SlackNotifier.call(@generation) }

    assert_requested post_message
  end

  test 'uploads the output into the DM when asked' do
    @user.update!(notify_include_asset: true)
    stub_request(:post, "#{API}files.getUploadURLExternal")
      .with(body: hash_including('filename' => 'out.png'))
      .to_return(body: { ok: true, upload_url: 'https://files.slack.test/upload/abc', file_id: 'F1' }.to_json)
    upload = stub_request(:post, 'https://files.slack.test/upload/abc').to_return(body: 'OK')
    complete = stub_request(:post, "#{API}files.completeUploadExternal")
               .with(body: hash_including('channel_id' => 'D999', 'files' => [{ id: 'F1', title: 'out.png' }].to_json))
               .to_return(body: { ok: true }.to_json)

    with_notifications_configured { SlackNotifier.call(@generation) }

    assert_requested upload
    assert_requested complete
  end

  test 'raises when Slack says no' do
    stub_request(:post, "#{API}chat.postMessage").to_return(body: { ok: false, error: 'not_allowed' }.to_json)

    error = assert_raises(SlackNotifier::Error) { with_notifications_configured { SlackNotifier.call(@generation) } }
    assert_match(/not_allowed/, error.message)
  end
end

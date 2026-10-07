require 'test_helper'

class VideoScriptJobTest < ActiveJob::TestCase
  COMPLETIONS = 'http://litellm.test/v1/chat/completions'.freeze

  setup do
    @previous = {
      'LITELLM_URL' => ENV.fetch('LITELLM_URL', nil),
      'LITELLM_MODEL' => ENV.fetch('LITELLM_MODEL', nil)
    }
    ENV['LITELLM_URL'] = 'http://litellm.test'
    ENV['LITELLM_MODEL'] = 'gpt-test'
    @script_request = users(:alice).video_script_requests.create!(message: 'Write a script for waves')
  end

  teardown do
    @previous.each { |key, value| ENV[key] = value }
  end

  test 'stores the cleaned-up script' do
    stub_request(:post, COMPLETIONS)
      .with { JSON.parse(it.body)['messages'] == [{ 'role' => 'user', 'content' => 'Write a script for waves' }] }
      .to_return(body: reply("```\nScript: Waves roll in at dusk.\n```"))

    VideoScriptJob.perform_now(@script_request.id)

    @script_request.reload

    assert_predicate @script_request, :succeeded?
    assert_equal 'Waves roll in at dusk.', @script_request.script
    assert_equal 1, @script_request.attempts
  end

  test 'tries once more when the first attempt fails' do
    stub_request(:post, COMPLETIONS).to_return({ status: 500, body: 'nope' }, { body: reply('Waves.') })

    VideoScriptJob.perform_now(@script_request.id)

    assert_predicate @script_request.reload, :succeeded?
    assert_equal 2, @script_request.attempts
  end

  test 'fails after the second attempt fails' do
    stub_request(:post, COMPLETIONS).to_return(status: 500, body: 'nope')

    VideoScriptJob.perform_now(@script_request.id)

    @script_request.reload

    assert_predicate @script_request, :failed?
    assert_equal 2, @script_request.attempts
    assert_predicate @script_request.error, :present?
    assert_requested :post, COMPLETIONS, times: 2
  end

  test 'a cancelled request is not filled in' do
    stub_request(:post, COMPLETIONS).to_return do
      @script_request.cancelled!
      { body: reply('Too late.') }
    end

    VideoScriptJob.perform_now(@script_request.id)

    assert_predicate @script_request.reload, :cancelled?
    assert_nil @script_request.script
  end

  private

  def reply(content) = { choices: [{ message: { content: } }] }.to_json
end

require 'test_helper'

module LiteLlm
  class ClientTest < ActiveSupport::TestCase
    setup do
      @previous = {
        'LITELLM_URL' => ENV.fetch('LITELLM_URL', nil),
        'LITELLM_API_KEY' => ENV.fetch('LITELLM_API_KEY', nil),
        'LITELLM_MODEL' => ENV.fetch('LITELLM_MODEL', nil),
        'LITELLM_TIMEOUT_SECONDS' => ENV.fetch('LITELLM_TIMEOUT_SECONDS', nil)
      }
    end

    teardown do
      @previous.each { |key, value| ENV[key] = value }
    end

    test 'configured when url and model are set' do
      with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => 'gpt-test') do
        assert_predicate Client, :configured?
        assert_empty Client.missing_config_keys
      end
    end

    test 'chat sends an OpenAI-compatible request and returns the message content' do
      with_env('LITELLM_URL' => 'http://litellm.test/', 'LITELLM_MODEL' => 'gpt-test',
               'LITELLM_API_KEY' => 'secret') do
        stub_request(:post, 'http://litellm.test/v1/chat/completions')
          .with(headers: { 'Authorization' => 'Bearer secret' }) do |request|
            body = JSON.parse(request.body)

            assert_equal 'gpt-test', body['model']
            assert_equal 'json_object', body.dig('response_format', 'type')
            assert_equal 'system rules', body.dig('messages', 0, 'content')
            assert_equal 'user payload', body.dig('messages', 1, 'content')
          end
          .to_return(body: { choices: [{ message: { content: '{"ok":true}' } }] }.to_json)

        assert_equal '{"ok":true}', Client.chat(system: 'system rules', user: 'user payload')
      end
    end

    test 'raises on HTTP errors' do
      with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => 'gpt-test') do
        stub_request(:post, 'http://litellm.test/v1/chat/completions').to_return(status: 500, body: 'nope')

        error = assert_raises(Error) { Client.chat(system: 'x', user: 'y') }

        assert_match(/HTTP 500/, error.message)
      end
    end

    test 'raises when the proxy cannot be reached' do
      with_env('LITELLM_URL' => 'http://litellm.test', 'LITELLM_MODEL' => 'gpt-test') do
        stub_request(:post, 'http://litellm.test/v1/chat/completions').to_raise(Errno::ECONNREFUSED)

        error = assert_raises(Error) { Client.chat(system: 'x', user: 'y') }

        assert_match(/Couldn't reach LiteLLM/, error.message)
      end
    end
  end
end

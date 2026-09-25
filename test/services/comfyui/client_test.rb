require 'test_helper'

module Comfyui
  class ClientTest < ActiveSupport::TestCase
    setup do
      @backend = backends(:gpu)
      @client = Client.new(@backend)
    end

    test 'submit posts the graph with our client id and returns the prompt id' do
      graph = { '1' => { 'class_type' => 'X', 'inputs' => {} } }
      stub = stub_request(:post, comfy_url(@backend, 'prompt'))
             .with(body: { prompt: graph, client_id: Client::CLIENT_ID }.to_json)
             .to_return(body: { prompt_id: 'abc-123', number: 1, node_errors: {} }.to_json)

      assert_equal 'abc-123', @client.submit(graph)
      assert_requested stub
    end

    test 'submit explains why ComfyUI rejected the workflow' do
      body = {
        error: { type: 'prompt_outputs_failed_validation', message: 'Prompt outputs failed validation' },
        node_errors: {
          '4' => { class_type: 'CheckpointLoaderSimple',
                   errors: [{ message: 'Value not in list', details: 'ckpt_name: missing.safetensors' }] }
        }
      }
      stub_request(:post, comfy_url(@backend, 'prompt')).to_return(status: 400, body: body.to_json)

      error = assert_raises(PromptRejected) { @client.submit({}) }
      assert_equal 'Prompt outputs failed validation. CheckpointLoaderSimple: Value not in list — ' \
                   'ckpt_name: missing.safetensors', error.message
    end

    test 'sends the auth token as a bearer header' do
      @backend.auth_token = 'tok'
      stub = stub_request(:get, comfy_url(@backend, 'system_stats'))
             .with(headers: { 'Authorization' => 'Bearer tok' }).to_return(body: '{}')

      @client.system_stats

      assert_requested stub
    end

    test 'does not send an auth header without a token' do
      stub_request(:get, comfy_url(@backend, 'system_stats')).to_return(body: '{}')

      @client.system_stats

      assert_requested(:get, comfy_url(@backend, 'system_stats')) { |req| !req.headers.key?('Authorization') }
    end

    test 'auth failures point at the token' do
      stub_request(:get, comfy_url(@backend, 'system_stats')).to_return(status: 401)

      error = assert_raises(Error) { @client.system_stats }
      assert_match(/check the auth token/, error.message)
    end

    test 'network failures become ConnectionError' do
      stub_request(:get, comfy_url(@backend, 'queue')).to_timeout

      assert_raises(ConnectionError) { @client.queue_depth }
    end

    test 'non-JSON responses suggest the URL is wrong' do
      stub_request(:get, comfy_url(@backend, 'system_stats')).to_return(body: '<html>login</html>')

      error = assert_raises(Error) { @client.system_stats }
      assert_match(/pointing at ComfyUI/, error.message)
    end

    test 'queue_depth counts running and pending prompts' do
      stub_request(:get, comfy_url(@backend, 'queue'))
        .to_return(body: { queue_running: [[1, 'a']], queue_pending: [[2, 'b'], [3, 'c']] }.to_json)

      assert_equal 3, @client.queue_depth
    end

    test 'cancel_prompt dequeues and interrupts the prompt' do
      queue = stub_request(:post, comfy_url(@backend, 'queue')).with(body: { delete: ['abc-123'] }.to_json)
      interrupt = stub_request(:post, comfy_url(@backend, 'interrupt')).with(body: { prompt_id: 'abc-123' }.to_json)

      @client.cancel_prompt('abc-123')

      assert_requested queue
      assert_requested interrupt
    end

    test 'result wraps the history entry for the prompt' do
      stub_request(:get, comfy_url(@backend, 'history/abc'))
        .to_return(body: { abc: { status: { status_str: 'success', completed: true }, outputs: {} } }.to_json)

      assert_predicate @client.result('abc'), :success?
    end

    test 'result is pending while the prompt is not in history yet' do
      stub_request(:get, comfy_url(@backend, 'history/abc')).to_return(body: '{}')
      stub_request(:get, comfy_url(@backend, 'history')).with(query: { max_items: '64' }).to_return(body: '{}')

      assert_predicate @client.result('abc'), :pending?
    end

    test 'result falls back to scanning recent history' do
      entry = { status: { status_str: 'success', completed: true }, outputs: {} }
      recent = stub_request(:get, comfy_url(@backend, 'history')).with(query: { max_items: '64' })
      stub_request(:get, comfy_url(@backend, 'history/abc')).to_return(body: '{}')
      recent.to_return(body: { 'abc' => entry }.to_json)

      assert_predicate @client.result('abc'), :success?
    end

    test 'prompt_in_queue? checks running and pending prompts' do
      stub_request(:get, comfy_url(@backend, 'queue'))
        .to_return(body: { queue_running: [[1, 'running-id']], queue_pending: [[2, 'pending-id']] }.to_json)

      assert @client.prompt_in_queue?('running-id')
      assert @client.prompt_in_queue?('pending-id')
      assert_not @client.prompt_in_queue?('gone-id')
    end

    test 'download fetches the file through /view' do
      stub_request(:get, comfy_url(@backend, 'view'))
        .with(query: { filename: 'out.png', subfolder: 'x', type: 'output' }).to_return(body: 'PNGDATA')

      assert_equal 'PNGDATA', @client.download({ 'filename' => 'out.png', 'subfolder' => 'x', 'type' => 'output' })
    end

    test 'upload_image sends multipart and returns the name to reference' do
      stub = stub_request(:post, comfy_url(@backend, 'upload/image'))
             .with(headers: { 'Content-Type' => %r{\Amultipart/form-data} })
             .to_return(body: { name: 'in.png', subfolder: 'comfier', type: 'input' }.to_json)

      name = File.open(file_fixture('pixel.png')) do |file|
        @client.upload_image(file, filename: 'in.png', content_type: 'image/png')
      end

      assert_equal 'comfier/in.png', name
      assert_requested stub
    end

    test 'works with a base URL that includes a path prefix' do
      @backend.base_url = 'https://proxy.test/comfy'
      stub_request(:get, 'https://proxy.test/comfy/system_stats').to_return(body: '{"system":{}}')

      assert_equal({ 'system' => {} }, @client.system_stats)
    end

    test 'model_files lists a folder with forward slashes and treats unknown folders as empty' do
      stub_request(:get, comfy_url(@backend, 'models/loras')).to_return(body: ['sub\\a.safetensors', 'b.pt'].to_json)
      stub_request(:get, comfy_url(@backend, 'models/nope')).to_return(status: 404)

      assert_equal %w[sub/a.safetensors b.pt], @client.model_files('loras')
      assert_equal [], @client.model_files('nope')
    end

    test 'downloader_node? checks object_info for the Comfier node' do
      path = "object_info/#{Client::DOWNLOADER_NODE}"
      stub_request(:get, comfy_url(@backend, path)).to_return({ body: { Client::DOWNLOADER_NODE => {} }.to_json },
                                                              { body: '{}' }, { status: 404 })

      assert_predicate @client, :downloader_node?
      assert_not @client.downloader_node?
      assert_not @client.downloader_node?
    end

    test 'manager_version is nil when ComfyUI-Manager is not enabled' do
      stub_request(:get, comfy_url(@backend, 'v2/manager/version')).to_return({ body: "V4.2.2\n" }, { status: 404 })

      assert_equal 'V4.2.2', @client.manager_version
      assert_nil @client.manager_version
    end

    test 'a refused request raises Forbidden with a hint about the token' do
      stub_request(:get, comfy_url(@backend, 'v2/manager/queue/status')).to_return(status: 403)

      error = assert_raises(Forbidden) { @client.manager_queue_status }
      assert_match(/auth token/, error.message)
    end

    test 'manager_install_model queues the entry and starts the queue' do
      install = stub_request(:post, comfy_url(@backend, 'v2/manager/queue/install_model'))
                .with(body: { filename: 'a.safetensors' }.to_json)
      start = stub_request(:post, comfy_url(@backend, 'v2/manager/queue/start'))

      @client.manager_install_model('filename' => 'a.safetensors')

      assert_requested install
      assert_requested start
    end

    test 'manager_install_model explains a rejected entry' do
      stub_request(:post, comfy_url(@backend, 'v2/manager/queue/install_model')).to_return(status: 400, body: 'nope')

      error = assert_raises(Error) { @client.manager_install_model('filename' => 'a.safetensors') }
      assert_match(/rejected a.safetensors/, error.message)
    end
  end
end

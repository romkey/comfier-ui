require 'test_helper'

module Comfyui
  class GenerationCleanerTest < ActiveSupport::TestCase
    setup do
      @generation = generations(:alice_running)
      @backend = backends(:gpu)
      @backend.update!(cleanup_after_run: true)
      @history_url = comfy_url(@backend, 'history/running-prompt')
    end

    test 'cleans up files and history when the backend opts in' do
      stub_request(:get, @history_url).to_return(body: {
        'running-prompt' => {
          status: { status_str: 'success', completed: true },
          outputs: { '9' => { images: [{ filename: 'out.png', subfolder: '', type: 'output' }] } }
        }
      }.to_json)
      cleanup = stub_request(:post, comfy_url(@backend, 'comfier/cleanup'))
                .with(body: hash_including(
                  prompt_id: 'running-prompt',
                  input_image: 'comfier/in.png',
                  files: [{ filename: 'out.png', subfolder: '', type: 'output' }]
                ))

      @generation.update!(status: :succeeded, parameters: { backend_input_image: 'comfier/in.png' })

      assert_requested cleanup
    end

    test 'does nothing when cleanup is disabled' do
      @backend.update!(cleanup_after_run: false)

      @generation.update!(status: :succeeded)

      assert_not_requested :post, comfy_url(@backend, 'comfier/cleanup')
      assert_not_requested :post, comfy_url(@backend, 'history')
    end
  end
end

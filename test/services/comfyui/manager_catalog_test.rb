require 'test_helper'

module Comfyui
  class ManagerCatalogTest < ActiveSupport::TestCase
    test 'a named folder, with or without a subfolder' do
      assert_equal 'checkpoints/sd15.safetensors',
                   ManagerCatalog.path('filename' => 'sd15.safetensors', 'save_path' => 'checkpoints')
      assert_equal 'checkpoints/SD1.5/v1-5-pruned-emaonly.ckpt',
                   ManagerCatalog.path('filename' => 'v1-5-pruned-emaonly.ckpt', 'save_path' => 'checkpoints/SD1.5')
    end

    test 'default uses the usual folder for the type' do
      assert_equal 'vae/hunyuan_video_vae_bf16.safetensors',
                   ManagerCatalog.path('filename' => 'hunyuan_video_vae_bf16.safetensors', 'save_path' => 'default',
                                       'type' => 'VAE')
      assert_nil ManagerCatalog.path('filename' => 'x.onnx', 'save_path' => 'default', 'type' => 'insightface')
    end

    test 'ignores entries that do not make a safe path' do
      assert_nil ManagerCatalog.path('filename' => '', 'save_path' => 'checkpoints')
      assert_nil ManagerCatalog.path('filename' => 'x.safetensors', 'save_path' => '../evil')
    end
  end
end

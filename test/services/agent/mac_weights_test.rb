# frozen_string_literal: true

require 'test_helper'

module Agent
  class MacWeightsTest < ActiveSupport::TestCase
    FP8 = 'wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors'
    FP16 = 'wan2.2_t2v_high_noise_14B_fp16.safetensors'
    CONVERTED = 'wan2.2_t2v_high_noise_14B_fp16_from_fp8.safetensors'
    URL = "https://huggingface.co/Comfy-Org/Wan_2.2/resolve/main/split_files/diffusion_models/#{FP8}".freeze

    setup do
      @backend = create_agent_backend!(owner: users(:alice), agent_version: '0.4.13',
                                       system_json: { 'devices' => [{ 'name' => 'mps', 'type' => 'mps' }] })
    end

    def fp8_model(**extra)
      { 'folder' => 'diffusion_models', 'filename' => FP8, 'url' => URL, 'sha256' => 'a' * 64, 'bytes' => 14 }
        .merge(extra.stringify_keys)
    end

    def mac = MacWeights.new(@backend.reload)

    test 'fp16 names and links follow the fp8 name' do
      assert_equal FP16, MacWeights.fp16_name(FP8)
      assert_equal 'wan/umt5_xxl_fp16.safetensors', MacWeights.fp16_name('wan/umt5_xxl_fp8_e4m3fn_scaled.safetensors')
      assert_equal CONVERTED, MacWeights.converted_name(FP8)
      assert_equal "#{URL.delete_suffix(FP8)}#{FP16}?download=true",
                   MacWeights.fp16_url_guess("#{URL}?download=true", FP8)
      assert_nil MacWeights.fp16_url_guess('https://example.com/download/123', FP8)
    end

    test 'other servers keep fp8 files' do
      @backend.update!(system_json: { 'devices' => [{ 'type' => 'cuda' }] })

      assert_equal [fp8_model], mac.models([fp8_model])
    end

    test 'the official fp16 file stands in when its link is known' do
      swapped = mac.substitute(fp8_model(fp16_url: 'https://hf.test/fp16', fp16_bytes: 28, fp16_sha256: 'b' * 64))

      assert_equal({ 'folder' => 'diffusion_models', 'filename' => FP16, 'url' => 'https://hf.test/fp16',
                     'sha256' => 'b' * 64, 'bytes' => 28, 'replaces' => FP8 }, swapped)
    end

    test 'otherwise the fp8 file is downloaded and converted' do
      swapped = mac.substitute(fp8_model)

      assert_equal CONVERTED, swapped['filename']
      assert_equal MacWeights::CONVERT, swapped['convert']
      assert_equal [URL, 'a' * 64, 14], swapped.values_at('url', 'sha256', 'bytes')
    end

    test 'an fp16 copy already on the server wins' do
      @backend.backend_models.create!(folder: 'diffusion_models', filename: FP16)

      assert_equal FP16, mac.substitute(fp8_model)['filename']
    end

    test 'an agent too old to convert is a problem, not a stand-in' do
      @backend.update!(agent_version: '0.4.11')

      assert_nil mac.substitute(fp8_model)
      assert_match 'update the agent', mac.problem(fp8_model)
      assert_match 'use an fp16 or GGUF version', mac.problem(fp8_model(url: nil))
    end

    test 'the swap only happens when the fp16 models fit in memory' do
      umt5 = 'umt5_xxl_fp8_e4m3fn_scaled.safetensors'
      wan = [fp8_model(bytes: 14_293_923_632), fp8_model(filename: FP8.sub('high', 'low'), bytes: 14_293_923_632),
             fp8_model(folder: 'text_encoders', filename: umt5, bytes: 6_735_906_897)]
      graph = { '1' => { 'class_type' => 'UNETLoader', 'inputs' => { 'unet_name' => FP8 } } }
      @backend.update!(system_json: @backend.system_json.merge('ram_total_bytes' => 96.gigabytes))

      assert_equal wan, mac.models(wan)
      assert_equal graph, mac.rewrite(graph, wan)
      big_fp16 = { '1' => { 'class_type' => 'UNETLoader',
                            'inputs' => { 'unet_name' => 'big_fp16.safetensors', 'weight_dtype' => 'fp8_e4m3fn' } } }
      big = [fp8_model(filename: 'big_fp16.safetensors', bytes: 90.gigabytes)]

      assert_equal 'default', mac.rewrite(big_fp16, big).dig('1', 'inputs', 'weight_dtype')
      assert_equal 1, mac.problems(wan).size
      assert_match(/need about 66 GB of memory as fp16 .* has 96 GB, too little/, mac.problems(wan).first)
      assert_empty mac.problems([fp8_model(filename: 'vae.safetensors', bytes: 200.gigabytes)])

      @backend.update!(system_json: @backend.system_json.merge('ram_total_bytes' => 128.gigabytes))

      assert_equal CONVERTED, mac.models(wan).first['filename']
      assert_empty mac.problems(wan)
    end

    test 'jobs name the stand-ins and drop fp8 weight_dtype' do
      loader = { 'unet_name' => FP8, 'weight_dtype' => 'fp8_e4m3fn' }
      graph = { '1' => { 'class_type' => 'UNETLoader', 'inputs' => loader },
                '2' => { 'class_type' => 'KSampler', 'inputs' => { 'model' => ['1', 0], 'seed' => 5 } } }

      rewritten = mac.rewrite(graph, [fp8_model])

      assert_equal({ 'unet_name' => CONVERTED, 'weight_dtype' => 'default' }, rewritten['1']['inputs'])
      assert_equal graph['2'], rewritten['2']
      assert_equal FP8, graph['1']['inputs']['unet_name']
    end
  end
end

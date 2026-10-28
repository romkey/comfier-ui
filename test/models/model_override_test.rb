require 'test_helper'

class ModelOverrideTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  CHECKPOINT = 'v1-5-pruned-emaonly-fp16.safetensors'.freeze

  setup do
    @backend = create_agent_backend!(owner: users(:alice))
  end

  def build(**attrs)
    @backend.model_overrides.build({ folder: 'checkpoints', filename: CHECKPOINT,
                                     replacement_filename: 'sd15-q8.safetensors' }.merge(attrs))
  end

  test 'cleans up what an admin pastes' do
    override = build(filename: " #{CHECKPOINT} ", replacement_filename: 'sd\\sd15-q8.safetensors', sha256: 'A' * 64,
                     url: ' https://huggingface.co/x/y/blob/main/sd15-q8.safetensors ', note: '  ')
    override.validate

    assert_equal [CHECKPOINT, 'sd/sd15-q8.safetensors', 'a' * 64, nil],
                 [override.filename, override.replacement_filename, override.sha256, override.note]
    assert_equal 'https://huggingface.co/x/y/resolve/main/sd15-q8.safetensors', override.url
  end

  test 'the replacement must be another valid file with a valid link' do
    assert_includes build(replacement_filename: CHECKPOINT).tap(&:validate).errors[:replacement_filename],
                    'must be a different file'
    assert_predicate build(replacement_filename: CHECKPOINT, replacement_folder: 'unet'), :valid?
    assert_match(/single http\(s\) URL/, build(url: 'ftp://x/y').tap(&:validate).errors[:base].join)
    assert_match(/models folder/, build(replacement_folder: '../etc').tap(&:validate).errors[:base].join)
    assert_includes build(sha256: 'abc').tap(&:validate).errors[:sha256], 'must be 64 hexadecimal characters'
  end

  test 'one override per file for the server, and one per workflow' do
    build.save!

    assert_includes build.tap(&:validate).errors[:filename], 'already has an override'
    assert_predicate build(workflow: workflows(:sd_image)), :valid?
  end

  test 'applies to the same file in the same folder, or one ComfyUI treats as the same' do
    override = build(folder: 'unet', filename: 'flux.safetensors')

    assert override.applies_to?('folder' => 'diffusion_models', 'filename' => 'flux.safetensors')
    assert override.applies_to?('folder' => 'unknown', 'filename' => 'flux.safetensors')
    assert_not override.applies_to?('folder' => 'checkpoints', 'filename' => 'flux.safetensors')
    assert_not override.applies_to?('folder' => 'unet', 'filename' => 'flux-dev.safetensors')
  end

  test 'its stand-in names the replacement and drops the fp16 link and conversion' do
    override = build(replacement_folder: 'unet', url: 'https://hf.test/q8', sha256: 'b' * 64, bytes: 7)
    model = { 'folder' => 'checkpoints', 'filename' => CHECKPOINT, 'url' => 'https://hf.test/orig', 'source' => 'api',
              'fp16_url' => 'https://hf.test/fp16', 'convert' => 'fp8_to_fp16' }

    assert_equal({ 'folder' => 'unet', 'filename' => 'sd15-q8.safetensors', 'url' => 'https://hf.test/q8',
                   'sha256' => 'b' * 64, 'bytes' => 7, 'source' => 'api', 'overrides' => "checkpoints/#{CHECKPOINT}" },
                 override.stand_in(model))
  end

  test "a new link forgets the old file's size and checksum, unless they come with it" do
    override = build(url: 'https://hf.test/a', bytes: 5, sha256: 'a' * 64).tap(&:save!)

    override.update!(url: 'https://hf.test/b')

    assert_equal [nil, nil], override.reload.values_at(:bytes, :sha256)
    override.update!(url: 'https://hf.test/c', sha256: 'c' * 64)

    assert_equal [nil, 'c' * 64], override.reload.values_at(:bytes, :sha256)
  end

  test 'saving refreshes availability and looks up the size; editing only the note does neither' do
    override = build(url: 'https://huggingface.co/x/sd15-q8.safetensors')
    assert_enqueued_with(job: RecomputeAvailabilityJob, args: [{ backend_id: @backend.id }]) { override.save! }

    assert_enqueued_with(job: EnrichModelOverrideJob, args: [override])
    clear_enqueued_jobs
    override.update!(note: 'fp16 gives noise here')

    assert_no_enqueued_jobs
  end
end

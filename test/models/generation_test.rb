require 'test_helper'

class GenerationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:alice)
  end

  def build(workflow = workflows(:sd_image), **attrs)
    @user.generations.new({ workflow:, prompt: 'A red fox' }.merge(attrs))
  end

  test 'takes its kind from the workflow' do
    generation = build(workflows(:wan_video))
    generation.save!

    assert_equal 'video', generation.kind
    assert_predicate generation, :queued?
  end

  test 'picks a random seed when none is given' do
    generation = build
    generation.save!

    assert_kind_of Integer, generation.seed
    assert_includes 0..Generation::MAX_SEED, generation.seed
  end

  test 'keeps a seed the user chose and clamps it to range' do
    assert_equal 1234, build(seed: '1234').tap(&:save!).seed
    assert_equal Generation::MAX_SEED, build(seed: (2**40).to_s).tap(&:save!).seed
  end

  test 'turns the aspect ratio into dimensions from the base resolution' do
    square = build(aspect_ratio: '1:1').tap(&:save!)

    assert_equal [512, 512], [square.width, square.height]

    wide = build(workflows(:sdxl_image), aspect_ratio: '16:9').tap(&:save!)

    assert_equal [1344, 768], [wide.width, wide.height]
  end

  test 'falls back to the user default aspect ratio' do
    generation = users(:bob).generations.new(workflow: workflows(:sd_image), prompt: 'x', aspect_ratio: 'bogus')
    generation.save!

    assert_equal '16:9', generation.aspect_ratio
  end

  test 'turns a duration into frames at the workflow frame rate' do
    generation = build(workflows(:wan_video), duration: '5').tap(&:save!)

    assert_equal 5, generation.duration
    assert_equal 81, generation.frames
  end

  test 'uses the kind default duration and clamps long ones' do
    assert_equal 5, build(workflows(:wan_video)).tap(&:save!).duration
    assert_equal Generation::DURATION_RANGE.max, build(workflows(:wan_video), duration: '600').tap(&:save!).duration
  end

  test 'only stores parameters the workflow uses' do
    generation = build(workflows(:image_to_3d), prompt: nil, input_image: png_upload).tap(&:save!)

    assert_equal %w[seed], generation.parameters.keys
  end

  test 'requires a prompt only when the workflow has one' do
    assert_not build(prompt: '').valid?
    assert_predicate build(workflows(:image_to_3d), prompt: '', input_image: png_upload), :valid?
  end

  test 'requires an input image when the workflow takes one' do
    generation = build(workflows(:image_to_3d))

    assert_not generation.valid?
    assert_includes generation.errors[:input_image], 'is required'
  end

  test 'requires an enabled workflow' do
    assert_not build(nil).valid?
    assert_not build(workflows(:retired_image)).valid?
  end

  test 'placeholder_values covers every placeholder the workflow needs' do
    generation = build(negative_prompt: nil).tap(&:save!)
    values = generation.placeholder_values

    assert_empty workflows(:sd_image).placeholders.to_a - values.keys
    assert_equal '', values['negative_prompt']
    assert_equal 'uploaded.png', generation.placeholder_values(image: 'uploaded.png')['image']
  end

  test 'reusable_attributes can recreate an equivalent generation' do
    original = generations(:alice_done)
    copy = @user.generations.new(original.reusable_attributes)
    copy.save!

    assert_equal original.prompt, copy.prompt
    assert_equal original.aspect_ratio, copy.aspect_ratio
    assert_equal original.workflow, copy.workflow
  end

  test 'fail! and succeed! record the outcome' do
    generation = generations(:alice_running)
    generation.fail!('Boom')

    assert_predicate generation, :failed?
    assert_equal 'Boom', generation.error_message
    assert_not_nil generation.completed_at

    generation.succeed!

    assert_predicate generation, :succeeded?
    assert_nil generation.error_message
  end

  test 'queue_wait_seconds and processing_seconds come from processing timestamps' do
    generation = generations(:alice_done)

    assert_in_delta 45, generation.queue_wait_seconds, 1
    assert_in_delta 28.5, generation.processing_seconds, 1
  end

  test 'record_processing_times! stores ComfyUI execution timestamps' do
    generation = generations(:alice_running)
    started = Time.zone.at(1_700_000_000)
    ended = started + 12.seconds
    result = Comfyui::Result.new(
      'status' => {
        'status_str' => 'success',
        'messages' => [
          ['execution_start', { 'timestamp' => started.to_f * 1000 }],
          ['execution_success', { 'timestamp' => ended.to_f * 1000 }]
        ]
      },
      'outputs' => {}
    )

    generation.record_processing_times!(result)
    generation.reload

    assert_in_delta started, generation.processing_started_at, 0.001
    assert_in_delta ended, generation.processing_ended_at, 0.001
    assert_in_delta 12, generation.run_seconds, 0.01
  end

  test 'timed_out? compares against the submission time' do
    generation = generations(:alice_running)

    assert_not generation.timed_out?
    generation.submitted_at = 2.hours.ago

    assert_predicate generation, :timed_out?
  end

  test 'title prefers the prompt' do
    assert_equal 'A lighthouse at dusk', generations(:alice_done).title
    assert_equal 'Image #5', Generation.new(id: 5, kind: 'image').title
  end

  test 'snapshots the workflow name on create' do
    generation = build.tap(&:save!)

    assert_equal 'SD 1.5', generation.workflow_name
    assert_equal 'SD 1.5', generation.style_name
  end

  test 'quality and prompt strength scale workflow defaults' do
    workflow = workflows(:sd_image)
    workflow.update!(graph: workflow.graph.merge(
      '10' => { 'class_type' => 'KSampler', 'inputs' => { 'steps' => '{{steps}}', 'cfg' => '{{cfg}}' } }
    ))
    generation = build(workflow, quality: 'fast', cfg_level: 'strict').tap(&:save!)

    assert_equal 10, generation.steps
    assert_in_delta 9.1, generation.cfg, 0.1
  end

  test 'denoise and batch size are stored when the workflow uses them' do
    workflow = workflows(:sd_image)
    workflow.update!(graph: workflow.graph.merge(
      '11' => { 'class_type' => 'KSampler', 'inputs' => { 'denoise' => '{{denoise}}' } },
      '12' => { 'class_type' => 'EmptyLatentImage', 'inputs' => { 'batch_size' => '{{batch_size}}' } }
    ))
    generation = build(workflow, denoise: '0.45', batch_size: '3').tap(&:save!)

    assert_in_delta 0.45, generation.denoise
    assert_equal 3, generation.batch_size
  end

  test 'share! and unshare! toggle visibility' do
    generation = generations(:alice_done)

    generation.share!(share_prompt: false, share_input: true)

    assert_predicate generation, :shared?
    assert_not generation.share_prompt?
    assert_predicate generation, :share_input?

    generation.unshare!

    assert_not generation.shared?
  end

  test 'finishing notifies the owner when they turned notifications on' do
    @user.update!(notify_email: true)
    generation = generations(:alice_running)

    with_notifications_configured do
      assert_enqueued_with(job: NotifyGenerationJob, args: [generation]) { generation.succeed! }
    end
  end

  test 'failing and cancelling notify too' do
    @user.update!(notify_email: true)

    with_notifications_configured do
      assert_enqueued_with(job: NotifyGenerationJob) { generations(:alice_running).fail!('Boom') }

      queued = build.tap(&:save!)

      assert_enqueued_with(job: NotifyGenerationJob) { GenerationCanceller.call(queued) }
      assert_predicate queued, :cancelled?
      assert_equal :cancelled, queued.outcome
    end
  end

  test 'no notification for other updates or when notifications are off' do
    generation = generations(:alice_running)

    with_notifications_configured do
      assert_no_enqueued_jobs(only: NotifyGenerationJob) { generation.succeed! }

      @user.update!(notify_email: true)

      assert_no_enqueued_jobs(only: NotifyGenerationJob) { generation.update!(prompt: 'Changed') }
    end
  end
end

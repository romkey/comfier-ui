require 'test_helper'

class GenerationReferenceTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
    @workflow = workflows(:image_to_3d)
    @source = @user.generations.create!(workflow: @workflow, input_image: png_upload('original.png'))
    @original_blob = @source.input_image.blob
    @source.outputs.attach(io: StringIO.new(png_bytes), filename: 'out.png', content_type: 'image/png')
    @source.succeed!
  end

  test 'lists original and result when both exist' do
    assert_equal %w[original result], GenerationReference.available_sources(@source)
  end

  test 'defaults to the last result when available' do
    assert_equal 'result', GenerationReference.default_source(@source)
  end

  test 'attach_from_form reuses the chosen blob without a new upload' do
    target = @user.generations.new(workflow: @workflow)

    GenerationReference.attach_from_form!(
      target, user: @user, from_id: @source.id, source_type: 'original'
    )

    assert_equal @original_blob, target.input_image.blob

    target = @user.generations.new(workflow: @workflow)
    GenerationReference.attach_from_form!(
      target, user: @user, from_id: @source.id, source_type: 'result'
    )

    assert_equal @source.outputs.first.blob, target.input_image.blob
  end
end

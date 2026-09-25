require 'test_helper'

class GenerationNotificationTest < ActiveSupport::TestCase
  setup do
    @generation = generations(:alice_done)
    @generation.outputs.attach(io: file_fixture('pixel.png').open, filename: 'out.png', content_type: 'image/png')
    @generation.user.update!(notify_include_asset: true)
    app_settings(:default).update!(email_notification_attachment_max_mb: 20, slack_notification_attachment_max_mb: 0)
  end

  test 'uses separate attachment limits per channel' do
    email = GenerationNotification.new(@generation, channel: :email)
    slack = GenerationNotification.new(@generation, channel: :slack)

    assert_equal ['out.png'], email.attachable_files.map(&:filename)
    assert_empty slack.attachable_files
    assert_not email.files_left_out?
    assert_predicate slack, :files_left_out?
  end

  test 'passes through non-image files without processing when they fit' do
    @generation.outputs.purge
    @generation.outputs.attach(
      io: StringIO.new('plain text output'),
      filename: 'notes.txt',
      content_type: 'text/plain'
    )

    email = GenerationNotification.new(@generation, channel: :email)

    assert_equal ['notes.txt'], email.attachable_files.map(&:filename)
    assert_equal 'plain text output', email.attachable_files.first.data
  end

  test 'skips non-image files that exceed the limit' do
    @generation.outputs.purge
    @generation.outputs.attach(
      io: StringIO.new('x' * 100),
      filename: 'big.txt',
      content_type: 'text/plain'
    )
    app_settings(:default).update!(email_notification_attachment_max_mb: 0.00001)

    email = GenerationNotification.new(@generation, channel: :email)

    assert_empty email.attachable_files
    assert_predicate email, :files_left_out?
  end

  test 'shrinks oversized images to fit the email limit' do
    skip 'libvips required' unless vips_available?

    large_png = Vips::Image.gaussnoise(1800, 1800).write_to_buffer('.png')
    assert_operator large_png.bytesize, :>, 500.kilobytes

    @generation.outputs.purge
    @generation.outputs.attach(
      io: StringIO.new(large_png),
      filename: 'large.png',
      content_type: 'image/png'
    )
    app_settings(:default).update!(email_notification_attachment_max_mb: 0.488)

    email = GenerationNotification.new(@generation, channel: :email)
    files = email.attachable_files

    assert_equal 1, files.size, 'expected oversized image to be shrunk into the email attachment limit'
    assert_equal 'image/jpeg', files.first.content_type
    assert_equal 'large.jpg', files.first.filename
    assert_operator files.first.bytesize, :<=, AppSetting.email_notification_attachment_max_bytes
    assert_not email.files_left_out?
  end
end

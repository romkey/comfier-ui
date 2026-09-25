require 'test_helper'

class GenerationMailerTest < ActionMailer::TestCase
  setup do
    @generation = generations(:alice_done)
    @generation.outputs.attach(io: file_fixture('pixel.png').open, filename: 'out.png', content_type: 'image/png')
    @user = @generation.user
  end

  test 'says the result is ready and links to it' do
    mail = GenerationMailer.finished(@generation)

    assert_equal ['alice@example.com'], mail.to
    assert_equal 'Your image is ready', mail.subject
    assert_includes mail.text_part.body.to_s, "/results/#{@generation.id}"
    assert_empty mail.attachments
  end

  test 'names failures and cancellations' do
    failed = generations(:alice_failed)

    assert_equal 'Your video failed', GenerationMailer.finished(failed).subject
    assert_includes GenerationMailer.finished(failed).text_part.body.to_s, 'Value not in list'

    failed.update!(error_message: Generation::CANCELLED_MESSAGE)

    assert_equal 'Your video was cancelled', GenerationMailer.finished(failed).subject
  end

  test 'attaches the output when asked' do
    @user.update!(notify_include_asset: true)
    mail = GenerationMailer.finished(@generation)

    assert_equal ['out.png'], mail.attachments.map(&:filename)
  end

  test 'links instead of attaching outputs over the size cap' do
    @user.update!(notify_include_asset: true)
    app_settings(:default).update!(notification_attachment_max_mb: 0)

    mail = GenerationMailer.finished(@generation)

    assert_empty mail.attachments
    assert_includes mail.text_part.body.to_s, 'Too large to attach'
  end
end

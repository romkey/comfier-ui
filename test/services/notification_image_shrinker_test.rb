require 'test_helper'

class NotificationImageShrinkerTest < ActiveSupport::TestCase
  test 'processable types include common raster formats' do
    assert NotificationImageShrinker.processable?('image/png')
    assert NotificationImageShrinker.processable?('image/jpeg')
    assert NotificationImageShrinker.processable?('image/webp')
    assert_not NotificationImageShrinker.processable?('image/gif')
    assert_not NotificationImageShrinker.processable?('video/mp4')
  end

  test 'returns the original bytes when the image already fits' do
    blob = attach_blob('pixel.png', 'image/png')

    attachment = NotificationImageShrinker.prepare(blob, max_bytes: 1.megabyte)

    assert_equal 'pixel.png', attachment.filename
    assert_equal 'image/png', attachment.content_type
    assert_equal blob.download, attachment.data
  end

  test 'shrinks oversized png output to jpeg under the cap' do
    skip 'libvips required' unless vips_available?

    large_png = Vips::Image.gaussnoise(1800, 1800).write_to_buffer('.png')
    blob = attach_blob_data(large_png, 'large.png', 'image/png')

    attachment = NotificationImageShrinker.prepare(blob, max_bytes: 500.kilobytes)

    assert attachment, 'expected oversized png to be shrunk for notification attachment'
    assert_equal 'large.jpg', attachment.filename
    assert_equal 'image/jpeg', attachment.content_type
    assert_operator attachment.bytesize, :<=, 500.kilobytes
  end

  private

  def attach_blob(name, content_type)
    attach_blob_data(file_fixture(name).read, name, content_type)
  end

  def attach_blob_data(data, name, content_type)
    generation = generations(:alice_done)
    generation.outputs.attach(io: StringIO.new(data), filename: name, content_type:)
    generation.outputs.last.blob
  end
end

# Shrinks JPEG, PNG and WebP outputs until they fit a notification size cap.
class NotificationImageShrinker
  PROCESSABLE_TYPES = %w[image/jpeg image/jpg image/png image/webp].freeze
  QUALITIES = [85, 70, 55, 40, 25].freeze
  SCALES = [1.0, 0.75, 0.5, 0.35, 0.25].freeze

  class << self
    def processable?(content_type)
      PROCESSABLE_TYPES.include?(content_type.to_s.downcase)
    end

    def prepare(blob, max_bytes:)
      return nil unless processable?(blob.content_type)
      return nil if max_bytes.zero?

      original = blob.download
      return NotificationAttachment.from_blob(blob, data: original) if original.bytesize <= max_bytes

      shrink_until_fits(original, blob:, max_bytes:)
    end

    private

    def shrink_until_fits(source, blob:, max_bytes:)
      SCALES.each do |scale|
        QUALITIES.each do |quality|
          attachment = attempt(source, blob:, scale:, quality:)
          return attachment if attachment && attachment.bytesize <= max_bytes
        end
      end
      nil
    end

    def attempt(source, blob:, scale:, quality:)
      require 'vips'
      require 'image_processing/vips'

      max_dimension = compute_max_dimension(source, scale)
      return nil if max_dimension.zero?

      data = ImageProcessing::Vips
             .source(StringIO.new(source))
             .resize_to_limit!(max_dimension, max_dimension)
             .convert('jpg')
             .saver(quality:, strip: true)
             .call
             .read

      NotificationAttachment.new(
        filename: jpg_filename(blob.filename.to_s),
        content_type: 'image/jpeg',
        data:
      )
    rescue StandardError
      nil
    end

    def compute_max_dimension(source, scale)
      require 'vips'

      image = Vips::Image.new_from_buffer(source, '')
      side = [(image.width * scale).round, (image.height * scale).round, 1].max
      [side, 1].max
    rescue StandardError
      0
    end

    def jpg_filename(name)
      name.sub(/\.[^.]+\z/i, '.jpg')
    end
  end
end

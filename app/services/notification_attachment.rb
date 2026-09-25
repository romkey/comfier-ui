# A file payload ready to attach to an email or Slack notification.
class NotificationAttachment
  attr_reader :filename, :content_type, :data

  def initialize(filename:, content_type:, data:)
    @filename = filename
    @content_type = content_type
    @data = data
  end

  def bytesize = data.bytesize

  def self.from_blob(blob, data: nil)
    new(filename: blob.filename.to_s, content_type: blob.content_type, data: data || blob.download)
  end
end

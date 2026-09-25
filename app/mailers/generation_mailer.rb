# Tells a user their generation finished, failed or was cancelled.
class GenerationMailer < ApplicationMailer
  def self.configured? = ENV['SMTP_ADDRESS'].present?

  def finished(generation)
    @notification = GenerationNotification.new(generation, channel: :email)
    @notification.attachable_files.each do |attachment|
      attachments[attachment.filename] = { mime_type: attachment.content_type, content: attachment.data }
    end

    mail(to: generation.user.email, subject: @notification.headline)
  end
end

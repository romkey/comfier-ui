# Tells a user their generation finished, failed or was cancelled.
class GenerationMailer < ApplicationMailer
  def self.configured? = ENV['SMTP_ADDRESS'].present?

  def finished(generation)
    @notification = GenerationNotification.new(generation)
    @notification.attachable_files.each do |output|
      attachments[output.filename.to_s] = { mime_type: output.content_type, content: output.download }
    end

    mail(to: generation.user.email, subject: @notification.headline)
  end
end

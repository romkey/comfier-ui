# What we tell a user when one of their generations finishes, shared by email and Slack.
class GenerationNotification
  HEADLINES = {
    succeeded: 'Your %s is ready',
    failed: 'Your %s failed',
    cancelled: 'Your %s was cancelled'
  }.freeze

  attr_reader :generation, :channel

  def initialize(generation, channel:)
    @generation = generation
    @channel = channel.to_sym
  end

  delegate :outcome, :title, to: :generation

  def headline = format(HEADLINES.fetch(outcome), generation.kind_info.noun)

  def error_message = (generation.error_message if outcome == :failed)

  def url
    Rails.application.routes.url_helpers.generation_url(generation, **ActionMailer::Base.default_url_options)
  end

  def include_files? = generation.user.notify_include_asset? && generation.succeeded? && generation.outputs.attached?

  def max_bytes
    case channel
    when :email then AppSetting.email_notification_attachment_max_bytes
    when :slack then AppSetting.slack_notification_attachment_max_bytes
    else raise ArgumentError, "Unknown notification channel: #{channel.inspect}"
    end
  end

  # Attachments that fit under the size cap, in order, until the cap is used up.
  def attachable_files
    return [] unless include_files?

    budget = max_bytes
    generation.outputs.filter_map do |output|
      attachment = prepare_attachment(output, max_bytes: budget)
      next unless attachment

      budget -= attachment.bytesize
      attachment
    end
  end

  def files_left_out? = include_files? && attachable_files.size < generation.outputs.size

  private

  def prepare_attachment(output, max_bytes:)
    if NotificationImageShrinker.processable?(output.content_type)
      NotificationImageShrinker.prepare(output, max_bytes:)
    elsif output.byte_size <= max_bytes
      NotificationAttachment.from_blob(output)
    end
  end
end

# What we tell a user when one of their generations finishes, shared by email and Slack.
class GenerationNotification
  HEADLINES = {
    succeeded: 'Your %s is ready',
    failed: 'Your %s failed',
    cancelled: 'Your %s was cancelled'
  }.freeze

  attr_reader :generation

  def self.max_megabytes = ENV.fetch('NOTIFICATION_ATTACHMENT_MAX_MB', 20).to_i

  def self.max_bytes = max_megabytes.megabytes

  def initialize(generation)
    @generation = generation
  end

  delegate :outcome, :title, to: :generation

  def headline = format(HEADLINES.fetch(outcome), generation.kind_info.noun)

  def error_message = (generation.error_message if outcome == :failed)

  def url
    Rails.application.routes.url_helpers.generation_url(generation, **ActionMailer::Base.default_url_options)
  end

  def include_files? = generation.user.notify_include_asset? && generation.succeeded? && generation.outputs.attached?

  # Outputs that fit under the size cap, in order, until the cap is used up.
  def attachable_files
    return [] unless include_files?

    budget = self.class.max_bytes
    generation.outputs.select do |output|
      next false if output.byte_size > budget

      budget -= output.byte_size
      true
    end
  end

  def files_left_out? = include_files? && attachable_files.size < generation.outputs.size
end

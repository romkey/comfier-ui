# Owner notice after an admin moderates a reported result.
class ModerationNotification
  ACTIONS = {
    unshared: 'stopped sharing',
    link_revoked: 'revoked the public link for',
    removed: 'removed',
    deleted: 'deleted'
  }.freeze

  def initialize(user, title:, action:, category: nil)
    @user = user
    @title = title
    @action = action
    @category = category
  end

  def headline = 'Your result was moderated'

  def subject = headline

  def body
    verb = ACTIONS.fetch(@action)
    line = "An admin #{verb} \"#{@title}\" after a report"
    line += " (#{@category})" if @category.present?
    "#{line}."
  end

  def url
    base = ENV.fetch('APP_URL', 'http://localhost:3000').chomp('/')
    "#{base}#{Rails.application.routes.url_helpers.generations_path}"
  end

  def slack_text
    "#{body}\n<#{url}|Open Comfier>"
  end
end

# The privacy notice every user must agree to before using Comfier.
class PrivacyNotice < ApplicationRecord
  DEFAULT_BODY = <<~TEXT.freeze
    Comfier stores what you submit and what it produces on this server.

    • Your prompts, reference images and results are kept here so you can find them again.
    • Admins can see all of it, including jobs waiting in the queue.
    • If you share a result, every signed-in user can see the output, your prompt, and any reference image.
    • You can create a public link so people without an account can view a result. Public links show only the output.
    • Other users can see your name and what kind of job you're running while it's in the queue.

    Don't put anything here you wouldn't want an admin — or, if you share it, other members — to read.
  TEXT

  validates :body, presence: true
  validates :version, numericality: { only_integer: true, greater_than: 0 }

  def self.current
    first || create!(body: DEFAULT_BODY, version: 1)
  end
end

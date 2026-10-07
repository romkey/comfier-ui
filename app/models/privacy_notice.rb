# The privacy notice and code of conduct every user must agree to before using Comfier.
class PrivacyNotice < ApplicationRecord
  DEFAULT_CODE_OF_CONDUCT_URL = 'https://pdxhackerspace.org/code-of-conduct.pdf'.freeze
  DEFAULT_DECLINE_URL = 'https://www.disney.com'.freeze
  URL_FORMAT = %r{\Ahttps?://\S+\z}i

  DEFAULT_BODY = <<~TEXT.freeze
    To use Comfier you need to agree to the PDX Hackerspace Code of Conduct and understand how your work is stored.

    The Code of Conduct, in short:
    • PDX Hackerspace is a space for tolerance and respect. Everyone is welcome.
    • No harassment or discrimination, including intimidation, stalking, harassing images or recordings, and unwelcome sexual attention.
    • That covers what you make here too. Don't create or share anything that harasses, demeans or targets a person or group.

    Your privacy, in short — Comfier stores what you submit and what it produces on this server:
    • Your prompts, reference images and results are kept here so you can find them again.
    • Admins can see all of it, including jobs waiting in the queue.
    • If you share a result, every signed-in user can see the output and anything you chose to include with it.
    • Other users can see your name and what kind of job you're running while it's in the queue.
    • The owners of the backends, and other people who use those ComfyUI instances, may be able to see your work and results.

    Don't make or put anything here you wouldn't want an admin, a backend owner or other members to see.
  TEXT

  validates :body, presence: true
  validates :version, numericality: { only_integer: true, greater_than: 0 }
  validates :code_of_conduct_url, :decline_url,
            presence: true, format: { with: URL_FORMAT, message: 'must be an http(s) URL' }

  def safe_code_of_conduct_url = self.class.safe_url(code_of_conduct_url) || DEFAULT_CODE_OF_CONDUCT_URL
  def safe_decline_url = self.class.safe_url(decline_url) || DEFAULT_DECLINE_URL

  # Only plain http(s) URLs with a host and no credentials leave Comfier through these links.
  def self.safe_url(url)
    url = url.to_s
    return unless url.match?(URL_FORMAT)

    uri = URI.parse(url)
    return unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def self.current
    first || create!(body: DEFAULT_BODY, version: 1)
  end
end

# The privacy notice and code of conduct every user must agree to before using Comfier.
class PrivacyNotice < ApplicationRecord
  DEFAULT_CODE_OF_CONDUCT_URL = 'https://pdxhackerspace.org/code-of-conduct.pdf'.freeze
  DEFAULT_DECLINE_URL = 'https://www.disney.com'.freeze

  DEFAULT_BODY = <<~TEXT.freeze
    To use Comfier you need to agree to the PDX Hackerspace Code of Conduct and understand how your work is stored.

    The Code of Conduct, in short:
    • PDX Hackerspace is a space for tolerance and respect. Everyone is welcome.
    • No harassment or discrimination, including intimidation, stalking, harassing images or recordings, and unwelcome sexual attention.
    • That covers what you make here too. Don't create or share anything that harasses, demeans or targets a person or group.
    • Admins can warn you, remove your access, or expel you from PDX Hackerspace if you break it.

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
            presence: true, format: { with: %r{\Ahttps?://\S+\z}, message: 'must be an http(s) URL' }

  def self.current
    first || create!(body: DEFAULT_BODY, version: 1)
  end
end

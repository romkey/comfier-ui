class Report < ApplicationRecord
  CATEGORIES = {
    'code_of_conduct' => 'Code of Conduct violation',
    'illegal' => 'Illegal content',
    'sexual' => 'Sexual content',
    'violent' => 'Violent content',
    'harassment' => 'Harassment',
    'copyright' => 'Copyright',
    'other' => 'Other'
  }.freeze
  SOURCES = %w[member public].freeze

  belongs_to :report_case
  belongs_to :generation, optional: true
  belongs_to :reporter, class_name: 'User', optional: true

  validates :category, presence: true, inclusion: { in: CATEGORIES.keys }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :reason, presence: true, length: { maximum: 2000 }
  validates :reporter_digest, presence: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  def self.categories = CATEGORIES

  def self.digest_for(reporter_id: nil, ip: nil)
    key = reporter_id.present? ? "user:#{reporter_id}" : "ip:#{ip}"
    Digest::SHA256.hexdigest(key.to_s)
  end

  def category_label = CATEGORIES.fetch(category)

  def public? = source == 'public'

  def member? = source == 'member'
end

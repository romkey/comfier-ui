class MusicStylePreset < ApplicationRecord
  belongs_to :user

  normalizes :name, :description, with: ->(value) { value.strip }

  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { scope: :user_id }
  validates :description, presence: true, length: { maximum: 5_000 }

  scope :ordered, -> { order(:name, :id) }
end

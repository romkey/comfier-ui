# First-frame thumbnail for video results in grids and lists.
module GenerationVideoPoster
  extend ActiveSupport::Concern

  included do
    has_one_attached :output_poster

    after_update_commit :enqueue_video_poster_extraction, if: :enqueue_video_poster_extraction?
  end

  private

  def enqueue_video_poster_extraction?
    saved_change_to_status?(to: 'succeeded') && video? && !output_poster.attached?
  end

  def enqueue_video_poster_extraction
    ExtractVideoPosterJob.perform_later(self)
  end
end

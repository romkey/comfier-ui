# Cover art for audio results: an image generation (see AlbumArt) that the track's players show.
module GenerationAlbumArt
  extend ActiveSupport::Concern

  included do
    belongs_to :album_art_generation, class_name: 'Generation', optional: true
    has_many :album_art_tracks, class_name: 'Generation', foreign_key: :album_art_generation_id,
                                inverse_of: :album_art_generation, dependent: :nullify

    scope :with_album_art, -> { includes(album_art_generation: { outputs_attachments: :blob }) }

    # The track's page and card show the cover's progress, so redraw them when it changes.
    after_update_commit :refresh_album_art_tracks, if: :saved_change_to_status?
  end

  def album_art_image
    art = album_art_generation
    return unless art&.succeeded?

    art.outputs.find { it.content_type.to_s.start_with?('image/') }
  end

  def album_art_in_progress? = album_art_generation&.in_progress? || false

  private

  def refresh_album_art_tracks
    album_art_tracks.find_each do |track|
      track.broadcast_replace_later_to [track.user, :generations]
      track.broadcast_refresh_later_to track
    end
  end
end

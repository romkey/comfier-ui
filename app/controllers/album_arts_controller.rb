# Queues cover art for one of the user's audio results, from its prompt and lyrics (see AlbumArt).
class AlbumArtsController < ApplicationController
  def create
    audio = current_user.generations.find(params[:generation_id])
    return redirect_to generation_path(audio), alert: unavailable_reason(audio), status: :see_other \
      unless AlbumArt.available_for?(audio)
    return redirect_to generation_path(audio), alert: 'Album art is already being created.', status: :see_other \
      if audio.album_art_in_progress?

    AlbumArt.new(audio).create!(user: current_user)
    redirect_to generation_path(audio), notice: 'Creating album art. It will appear in the player when it\'s ready.',
                                        status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    redirect_to generation_path(audio), alert: e.record.errors.full_messages.to_sentence, status: :see_other
  end

  private

  def unavailable_reason(audio)
    return 'Album art is only for finished audio.' unless audio.audio? && audio.succeeded?

    'No image style is available for album art. Ask an admin to set one up.'
  end
end

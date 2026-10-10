# Serves a result's files to people who may see the result: its owner, an admin, or any signed-in member when it's
# on the Shared gallery. The URLs never expire, so a video player can come back for more bytes whenever it needs
# them (Active Storage's own URLs stop working after five minutes, which left players blank).
class GenerationOutputsController < ApplicationController
  include OutputServing

  before_action :set_generation

  def show
    attachment = @generation.outputs.find_by(id: params[:attachment_id])
    return head :not_found unless attachment

    serve_output(attachment, download: params[:download].present?)
  end

  # A video's first frame or a 3D model's preview.
  def poster
    return head :not_found unless @generation.output_poster.attached?

    serve_output(@generation.output_poster)
  end

  # An audio result's album art, which lives on its own image result.
  def cover
    image = @generation.album_art_image
    return head :not_found unless image

    serve_output(image)
  end

  def input_image
    return head :not_found unless @generation.input_image.attached?

    serve_output(@generation.input_image)
  end

  private

  def set_generation
    @generation = viewable_generations.find(params[:id])
  end

  def viewable_generations
    return Generation.all if current_user.admin?

    Generation.where(user: current_user).or(Generation.shared_gallery)
  end
end

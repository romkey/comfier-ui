# Anonymous viewer for a single result via an unguessable token.
class PublicSharesController < ApplicationController
  include OutputServing

  layout 'bare'
  allow_unauthenticated_access
  skip_privacy_gate

  before_action :set_generation
  before_action :set_noindex_headers, only: :show

  def show; end

  def output
    attachment = @generation.outputs.order(:id)[params[:index].to_i]
    return head :not_found unless attachment

    serve_output(attachment)
  end

  # An audio result's album art, which lives on its own image result.
  def cover
    image = @generation.album_art_image
    return head :not_found unless image

    serve_output(image)
  end

  private

  def set_generation
    @generation = Generation.succeeded.where(hidden_for_review_at: nil)
                            .with_attached_outputs.find_by!(public_token: params[:token])
  end

  def set_noindex_headers
    response.headers['Referrer-Policy'] = 'no-referrer'
  end
end

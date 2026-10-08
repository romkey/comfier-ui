# Anonymous viewer for a single result via an unguessable token.
class PublicSharesController < ApplicationController
  include OutputServing

  layout 'bare'
  allow_unauthenticated_access
  skip_privacy_gate

  before_action :set_generation
  before_action :set_noindex_headers, only: :show

  # Link-preview fetchers and crawlers, which would otherwise count every time a link is pasted somewhere.
  NON_VIEWER_AGENTS = %r{bot\b|crawl|spider|slurp|facebookexternalhit|embedly|preview|whatsapp|skype|vkshare|
                       pinterest|bitly|mastodon|pleroma|akkoma|misskey|curl|wget|python|go-http-client|headless|
                       okhttp|java/}ix

  def show
    @generation.record_public_view! if countable_view?
  end

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

  # People opening the link, not its owner or an admin checking on it, a preview fetcher, or a prefetch.
  def countable_view?
    return false if signed_in? && (current_user.id == @generation.user_id || current_user.admin?)
    return false if request.headers['Sec-Purpose'].to_s.include?('prefetch') ||
                    request.headers['Purpose'] == 'prefetch'

    agent = request.user_agent.to_s
    agent.present? && !NON_VIEWER_AGENTS.match?(agent)
  end

  def set_noindex_headers
    response.headers['Referrer-Policy'] = 'no-referrer'
  end
end

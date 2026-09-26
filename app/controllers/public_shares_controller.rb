# Anonymous viewer for a single result via an unguessable token.
class PublicSharesController < ApplicationController
  layout 'bare'
  allow_unauthenticated_access
  skip_privacy_gate

  before_action :set_generation
  before_action :set_noindex_headers, only: :show

  def show; end

  def output
    attachment = @generation.outputs.order(:id)[params[:index].to_i]
    return head :not_found unless attachment

    send_data attachment.download,
              filename: attachment.filename.to_s,
              type: attachment.content_type,
              disposition: 'inline'
  end

  private

  def set_generation
    @generation = Generation.succeeded.with_attached_outputs.find_by!(public_token: params[:token])
  end

  def set_noindex_headers
    response.headers['Referrer-Policy'] = 'no-referrer'
  end
end

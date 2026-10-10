# Video players report here when a result won't play (see video_player_controller.js), so admins can see under
# Log which browsers fail, how, and on which results. Public link viewers report too, so this needs no sign-in;
# it only writes a log line and is rate limited. The player sends the page's CSRF token like any other request.
class MediaErrorsController < ApplicationController
  allow_unauthenticated_access
  skip_privacy_gate

  rate_limit to: 20, within: 10.minutes, by: -> { request.remote_ip }, with: -> { head :too_many_requests }

  FIELDS = %w[code message network_state ready_state src video_width seconds retried visibility arrival morphs
              page].freeze

  def create
    details = report_details
    generation = reported_generation
    Rails.logger.warn("Video didn't play: #{details.to_json}")
    ActivityLog.record(kind: :media_failed, message: summary(details, generation), user: current_user,
                       subject: generation, details:, request:)
    head :no_content
  end

  private

  def report_details
    params.permit(*FIELDS).to_h.transform_values { it.to_s.truncate(200) }
  end

  def reported_generation
    id = params[:generation_id].presence
    Generation.find_by(id:) if id
  end

  def summary(details, generation)
    what = generation ? "“#{generation.title}”" : details['src'].presence || 'a video'
    reason = details['code'] == 'stalled' ? 'never started' : "failed (#{details['code'].presence || 'no code'})"
    "Video #{what} #{reason} on #{details['page']}"
  end
end

# Hides the message of the day for the current user until an admin changes it.
class MotdDismissalsController < ApplicationController
  def create
    current_user.update!(dismissed_motd_digest: params.require(:digest).to_s.first(64))
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove('motd') }
      format.html { redirect_back_or_to root_path, status: :see_other }
    end
  end
end

class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[new create failure]
  layout 'bare'

  def new
    redirect_to root_path if signed_in?
  end

  def create
    auth = request.env['omniauth.auth']
    return redirect_to login_path, alert: 'That sign-in link has expired. Please sign in again.' if auth.nil?

    return_to = sign_in(User.from_omniauth(auth))
    redirect_to safe_return_path(return_to), status: :see_other
  end

  def failure
    redirect_to login_path, alert: "Sign-in failed: #{params[:message].to_s.humanize.presence || 'unknown error'}"
  end

  def destroy
    reset_session
    redirect_to login_path, notice: 'You have been signed out.', status: :see_other
  end
end

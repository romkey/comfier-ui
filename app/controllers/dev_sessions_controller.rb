class DevSessionsController < ApplicationController
  allow_unauthenticated_access
  before_action { head :not_found unless DevLogin.enabled? }

  def create
    if DevLogin.authenticate(params[:email], params[:password])
      redirect_to safe_return_path(sign_in(DevLogin.user)), status: :see_other
    else
      redirect_to login_path, alert: 'That email and password don’t match the developer login.', status: :see_other
    end
  end
end

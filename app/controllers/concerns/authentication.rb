module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_login
    helper_method :current_user, :signed_in?
  end

  class_methods do
    def allow_unauthenticated_access(**)
      skip_before_action(:require_login, **)
    end
  end

  private

  def current_user
    return @current_user if defined?(@current_user)

    user = session[:user_id] && User.find_by(id: session[:user_id])
    if user && session_current?(user)
      @current_user = user
    else
      reset_session if session[:user_id]
      @current_user = nil
    end
  end

  def signed_in? = current_user.present?

  def require_login
    return if signed_in?

    session[:return_to] = request.fullpath if request.get? && !request.xhr?
    redirect_to login_path
  end

  def require_admin
    head :not_found unless current_user&.admin?
  end

  def sign_in(user)
    return_to = session[:return_to]
    reset_session
    session[:user_id] = user.id
    session[:session_epoch] = AppSetting.current.session_epoch
    return_to
  end

  def session_current?(_user)
    expected = AppSetting.current.session_epoch
    actual = session[:session_epoch]
    return true if expected.zero? && actual.nil?

    actual.to_i == expected
  end

  def safe_return_path(path)
    path.is_a?(String) && path.start_with?('/') && !path.start_with?('//') ? path : root_path
  end
end

# One-time choices after sign-up, before using the app.
class OnboardingController < ApplicationController
  layout 'bare'
  skip_privacy_gate

  before_action :require_sharing_onboarding

  def sharing; end

  def update_sharing
    share = params[:share_by_default] == '1'
    current_user.update_columns(share_by_default: share, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    redirect_to safe_return_path(session.delete(:return_to)), notice: 'You\'re all set.', status: :see_other
  end

  private

  def require_sharing_onboarding
    return if current_user.share_by_default.nil?

    redirect_to safe_return_path(session[:return_to] || root_path), status: :see_other
  end
end

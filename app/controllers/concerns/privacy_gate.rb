# Sends users to the privacy page until they've agreed to the current notice.
module PrivacyGate
  extend ActiveSupport::Concern

  included do
    before_action :require_privacy_acceptance
  end

  class_methods do
    def skip_privacy_gate(**)
      skip_before_action(:require_privacy_acceptance, **)
    end
  end

  private

  def require_privacy_acceptance
    return unless signed_in?
    return if current_user.privacy_current?

    session[:return_to] ||= request.fullpath if request.get? && !request.xhr?
    redirect_to privacy_path, alert: 'Please read and agree to the privacy notice to continue.'
  end
end

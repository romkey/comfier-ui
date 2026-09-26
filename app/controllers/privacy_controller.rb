# Shows the privacy notice and records agreement.
class PrivacyController < ApplicationController
  layout 'bare'
  skip_privacy_gate

  def show
    @notice = PrivacyNotice.current
  end

  def accept
    notice = PrivacyNotice.current
    return_to = session[:return_to]
    # Agreeing must be recorded even when unrelated settings no longer validate, like a since-disabled
    # preferred backend; otherwise the user is stuck on this page.
    current_user.update_columns(privacy_accepted_version: notice.version, privacy_accepted_at: Time.current, # rubocop:disable Rails/SkipsModelValidations
                                updated_at: Time.current)
    if current_user.share_by_default.nil?
      redirect_to welcome_sharing_path, notice: 'Thanks — one more question.', status: :see_other
    else
      session.delete(:return_to)
      redirect_to safe_return_path(return_to), notice: 'Thanks — you\'re all set.', status: :see_other
    end
  end
end

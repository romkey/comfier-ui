# Shows the privacy notice and code of conduct, and records agreement.
class PrivacyController < ApplicationController
  layout 'bare'
  skip_privacy_gate

  # A notice page kept from an earlier session, say after I Do Not Agree and Back, carries a stale form token.
  # Show the notice again rather than a 422.
  rescue_from ActionController::InvalidAuthenticityToken do
    redirect_to privacy_path, alert: 'That page had expired. Please choose again.', status: :see_other
  end

  def show
    # Don't let Back show a copy whose buttons belong to an earlier session.
    response.headers['Cache-Control'] = 'no-store'
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

  def code_of_conduct
    redirect_to PrivacyNotice.current.safe_code_of_conduct_url, allow_other_host: true
  end

  # Declining signs the user out and sends them to the admin-chosen page.
  def decline
    url = PrivacyNotice.current.safe_decline_url
    ActivityLog.record(
      kind: :logout,
      user: current_user,
      message: "#{current_user.display_name} declined the code of conduct",
      details: { method: 'privacy_decline' },
      request:
    )
    reset_session
    redirect_to url, allow_other_host: true, status: :see_other
  end
end

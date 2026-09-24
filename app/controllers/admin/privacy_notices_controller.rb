module Admin
  class PrivacyNoticesController < BaseController
    def edit
      @notice = PrivacyNotice.current
    end

    def update
      @notice = PrivacyNotice.current
      body = params.expect(privacy_notice: [:body])[:body]
      if params[:require_reacceptance] == '1'
        @notice.update!(body:, version: @notice.version + 1)
      else
        @notice.update!(body:)
      end
      redirect_to edit_admin_privacy_notice_path, notice: 'Privacy notice saved.', status: :see_other
    end
  end
end

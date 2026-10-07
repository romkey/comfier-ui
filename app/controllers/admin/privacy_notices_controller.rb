module Admin
  class PrivacyNoticesController < BaseController
    def edit
      @notice = PrivacyNotice.current
    end

    def update
      @notice = PrivacyNotice.current
      attrs = params.expect(privacy_notice: %i[body code_of_conduct_url decline_url])
      attrs[:version] = @notice.version + 1 if params[:require_reacceptance] == '1'
      if @notice.update(attrs)
        redirect_to edit_admin_privacy_notice_path, notice: 'Code of Conduct and privacy notice saved.',
                                                    status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end

module Admin
  # The message of the day shown at the top of every page.
  class MotdsController < BaseController
    def edit
      @settings = AppSetting.current
    end

    def update
      @settings = AppSetting.current
      if @settings.update(params.expect(app_setting: [:motd_text]))
        notice = @settings.motd? ? 'Message of the day saved.' : 'Message of the day removed.'
        redirect_to edit_admin_motd_path, notice:, status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end

module Admin
  class AppSettingsController < BaseController
    def edit
      @settings = AppSetting.current
    end

    def update
      @settings = AppSetting.current
      if @settings.update(settings_params)
        redirect_to edit_admin_app_setting_path, notice: 'Settings saved.', status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end

    private

    def settings_params
      params.expect(app_setting: [:notification_attachment_max_mb])
    end
  end
end

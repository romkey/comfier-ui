module Admin
  class AssistantSettingsController < BaseController
    def edit
      @settings = AppSetting.current
    end

    def update
      @settings = AppSetting.current
      attrs = settings_params
      attrs[:placeholder_prompt] = nil if params[:reset_prompt] == '1'
      if @settings.update(attrs)
        redirect_to edit_admin_assistant_setting_path, notice: 'Workflow assistant settings saved.', status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end

    private

    def settings_params
      params.expect(app_setting: [:placeholder_prompt])
    end
  end
end

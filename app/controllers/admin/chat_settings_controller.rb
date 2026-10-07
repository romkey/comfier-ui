module Admin
  class ChatSettingsController < BaseController
    def edit
      @settings = AppSetting.current
      @chat_models = LiteLlm::Client.models
    end

    def update
      @settings = AppSetting.current
      @chat_models = LiteLlm::Client.models
      attrs = settings_params
      attrs[:video_script_prompt] = nil if params[:reset_video_script_prompt] == '1'
      if @settings.update(attrs)
        redirect_to edit_admin_chat_setting_path, notice: 'Chat settings saved.', status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end

    private

    def settings_params
      params.expect(app_setting: %i[chat_default_model chat_notice_text chat_notice_url video_script_prompt])
    end
  end
end

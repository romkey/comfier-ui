module Admin
  # The prompt and image style behind Create album art on audio results.
  class AlbumArtSettingsController < BaseController
    before_action :load_settings

    def edit; end

    def update
      attrs = settings_params
      attrs[:album_art_prompt] = nil if params[:reset_album_art_prompt] == '1'
      if @settings.update(attrs)
        redirect_to edit_admin_album_art_setting_path, notice: 'Album art settings saved.', status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end

    private

    def load_settings
      @settings = AppSetting.current
      @workflows = Workflow.where(kind: 'image').ordered.select { AlbumArt.usable_workflow?(it) }
    end

    def settings_params
      params.expect(app_setting: %i[album_art_workflow_id album_art_prompt])
    end
  end
end

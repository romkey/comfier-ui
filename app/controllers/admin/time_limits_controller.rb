module Admin
  # How long one run of each kind may take before it's stopped.
  class TimeLimitsController < BaseController
    def edit
      @settings = AppSetting.current
    end

    def update
      @settings = AppSetting.current
      if @settings.update(params.expect(app_setting: AppSetting::TIMEOUT_ATTRS.values))
        redirect_to edit_admin_time_limits_path, notice: 'Time limits saved.', status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end
  end
end

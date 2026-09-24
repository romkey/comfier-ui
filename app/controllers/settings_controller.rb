class SettingsController < ApplicationController
  include SettingsNav

  before_action :set_user

  def show; end

  def update
    if @user.update(settings_params)
      redirect_to settings_path, notice: 'Settings saved.', status: :see_other
    else
      render :show, status: :unprocessable_content
    end
  end

  private

  def set_user
    @user = current_user
    @backends = Backend.enabled.ordered.to_a
  end

  def settings_params
    params.expect(user: %i[preferred_backend_id default_aspect_ratio default_negative_prompt])
  end
end

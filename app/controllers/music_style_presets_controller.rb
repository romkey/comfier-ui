class MusicStylePresetsController < ApplicationController
  include SettingsNav

  before_action :set_preset, only: %i[edit update destroy]

  def index
    @pagy, @presets = pagy(:offset, current_user.music_style_presets.ordered, limit: 50)
  end

  def new
    @preset = current_user.music_style_presets.new
  end

  def edit; end

  def create
    @preset = current_user.music_style_presets.new(preset_params)
    if @preset.save
      redirect_to music_style_presets_path, notice: 'Music style preset saved.', status: :see_other
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @preset.update(preset_params)
      redirect_to music_style_presets_path, notice: 'Music style preset saved.', status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @preset.destroy!
    redirect_to music_style_presets_path, notice: 'Music style preset deleted.', status: :see_other
  end

  private

  def set_preset
    @preset = current_user.music_style_presets.find(params[:id])
  end

  def preset_params
    params.expect(music_style_preset: %i[name description])
  end
end

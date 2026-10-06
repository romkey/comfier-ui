class AddTimeLimitsToAppSettings < ActiveRecord::Migration[8.1]
  def change
    change_table :app_settings, bulk: true do |t|
      t.integer :image_timeout_minutes, default: 20, null: false
      t.integer :video_timeout_minutes, default: 240, null: false
      t.integer :audio_timeout_minutes, default: 30, null: false
      t.integer :model_3d_timeout_minutes, default: 60, null: false
    end
  end
end

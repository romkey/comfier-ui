class AddVideoScriptPromptToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :video_script_prompt, :text
  end
end

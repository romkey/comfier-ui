class AddPlaceholderPromptToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :placeholder_prompt, :text
  end
end

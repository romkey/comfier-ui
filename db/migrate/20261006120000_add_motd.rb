class AddMotd < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :motd_text, :text
    add_column :users, :dismissed_motd_digest, :string
  end
end

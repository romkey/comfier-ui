class AddAlbumArt < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :album_art_prompt, :text
    add_reference :app_settings, :album_art_workflow, foreign_key: { to_table: :workflows, on_delete: :nullify }
    add_reference :generations, :album_art_generation,
                  foreign_key: { to_table: :generations, on_delete: :nullify }
  end
end

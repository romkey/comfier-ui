class CreateMusicStylePresets < ActiveRecord::Migration[8.1]
  def change
    create_table :music_style_presets do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.text :description, null: false
      t.timestamps
    end
    add_index :music_style_presets, %i[user_id name], unique: true
  end
end

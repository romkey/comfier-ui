class CreateVideoScriptRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :video_script_requests do |t|
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: 'pending'
      t.text :message, null: false
      t.text :script
      t.text :error
      t.integer :attempts, null: false, default: 0
      t.timestamps
    end
  end
end

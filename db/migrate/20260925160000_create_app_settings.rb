class CreateAppSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :app_settings do |t|
      t.integer :notification_attachment_max_mb, null: false, default: 20
      t.timestamps
    end

    default_mb = ENV.fetch('NOTIFICATION_ATTACHMENT_MAX_MB', 20).to_i
    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          INSERT INTO app_settings (notification_attachment_max_mb, created_at, updated_at)
          VALUES (#{default_mb}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
    end
  end
end

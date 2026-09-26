class CreateContentReporting < ActiveRecord::Migration[8.1]
  def change
    create_table :report_cases do |t|
      t.references :generation, foreign_key: true
      t.string :generation_title, null: false
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: 'open'
      t.string :conclusion
      t.text :review_note
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.integer :reports_count, null: false, default: 0
      t.timestamps
    end

    add_index :report_cases, %i[generation_id status]
    add_index :report_cases, :status

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          CREATE UNIQUE INDEX index_report_cases_one_open_per_generation
          ON report_cases (generation_id)
          WHERE status = 'open' AND generation_id IS NOT NULL
        SQL
      end
      dir.down do
        execute 'DROP INDEX IF EXISTS index_report_cases_one_open_per_generation'
      end
    end

    create_table :reports do |t|
      t.references :report_case, null: false, foreign_key: true
      t.references :generation, foreign_key: true
      t.string :category, null: false
      t.text :reason, null: false
      t.citext :contact_email
      t.references :reporter, foreign_key: { to_table: :users }
      t.string :source, null: false
      t.string :reporter_digest, null: false
      t.timestamps
    end

    add_index :reports, %i[report_case_id reporter_digest], unique: true

    add_column :generations, :hidden_for_review_at, :datetime
    add_column :app_settings, :report_auto_hide_threshold, :integer, default: 3, null: false
  end
end

class AddSharingAndTimingToGenerations < ActiveRecord::Migration[8.1]
  def up
    change_table :generations, bulk: true do |t|
      t.string :workflow_name
      t.datetime :shared_at
      t.boolean :share_prompt, null: false, default: true
      t.boolean :share_input, null: false, default: false
      t.float :run_seconds
    end

    add_index :generations, :shared_at, where: 'shared_at IS NOT NULL'

    execute <<~SQL.squish
      UPDATE generations SET workflow_name = workflows.name
      FROM workflows WHERE generations.workflow_id = workflows.id
    SQL
  end

  def down
    remove_index :generations, :shared_at
    change_table :generations, bulk: true do |t|
      t.remove :workflow_name, :shared_at, :share_prompt, :share_input, :run_seconds
    end
  end
end

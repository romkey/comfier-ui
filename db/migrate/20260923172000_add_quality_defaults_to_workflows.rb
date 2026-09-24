class AddQualityDefaultsToWorkflows < ActiveRecord::Migration[8.1]
  def change
    change_table :workflows, bulk: true do |t|
      t.integer :steps, null: false, default: 20
      t.float :guidance, null: false, default: 7.0
    end
  end
end

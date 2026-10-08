class AddPublicViewCountToGenerations < ActiveRecord::Migration[8.1]
  def change
    change_table :generations, bulk: true do |t|
      t.integer :public_view_count, null: false, default: 0
      t.datetime :public_last_viewed_at
    end
  end
end

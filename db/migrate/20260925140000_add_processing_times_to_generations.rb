class AddProcessingTimesToGenerations < ActiveRecord::Migration[8.1]
  def change
    change_table :generations, bulk: true do |t|
      t.datetime :processing_started_at
      t.datetime :processing_ended_at
    end
  end
end

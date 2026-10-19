# Apple Silicon can't run fp8 weights, so there an fp8 model is swapped for an fp16 one: the official fp16 file
# when its link exists (fp16_*), else the fp8 file converted by the agent as it downloads (convert).
class AddMacFp16Weights < ActiveRecord::Migration[8.1]
  def change
    change_table :workflow_models, bulk: true do |t|
      t.text :fp16_url
      t.bigint :fp16_bytes
      t.string :fp16_sha256
      t.datetime :fp16_checked_at
    end
    add_column :model_downloads, :convert, :string
  end
end

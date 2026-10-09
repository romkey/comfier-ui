# mflux and MLX video models are downloaded by the engine on the server, by model name (an mflux model or a
# Hugging Face repo), not from a file link.
class AddEngineToModelDownloads < ActiveRecord::Migration[8.1]
  def change
    change_table :model_downloads, bulk: true do |t|
      t.string :engine
      t.change_null :url, true
    end
  end
end

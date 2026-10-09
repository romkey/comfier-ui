# Until now an empty engines_json meant "this agent didn't report engines", i.e. ComfyUI only. Rows get that
# spelled out, so an empty map can mean what an agent reports while nothing it runs is available.
class BackfillEnginesJson < ActiveRecord::Migration[8.1]
  COMFYUI_ONLY = { 'comfyui' => {} }.freeze

  def up
    change_column_default :backend_inventories, :engines_json, from: {}, to: COMFYUI_ONLY
    execute(<<~SQL.squish)
      UPDATE backend_inventories SET engines_json = '{"comfyui": {}}'::jsonb WHERE engines_json = '{}'::jsonb
    SQL
  end

  def down
    change_column_default :backend_inventories, :engines_json, from: COMFYUI_ONLY, to: {}
  end
end

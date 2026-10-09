# Macs whose agent runs the mflux and MLX video engines, and workflows for them.
module EngineTestHelpers
  # A Mac whose agent runs MLX engines, e.g. engines: { mflux: { models: %w[z-image-turbo] } }.
  def bring_mac_online!(backend, engines:, ram_gb: 64, comfyui: true)
    socket = connect_agent!(backend)
    agent_hello(backend, resources: { ram: { total_bytes: ram_gb.gigabytes } },
                         system: { devices: [{ name: 'Apple M3 Max', type: 'mps' }] })
    engines = engines.deep_stringify_keys
    agent_inventory(backend, engines: comfyui ? { 'comfyui' => {} }.merge(engines) : engines)
    agent_status(backend)
    socket
  end

  def engine_workflow!(name: 'Z-Image', preset: 'z-image-turbo', **attrs)
    recipe = EnginePreset.all.find { it.key == preset }
    Workflow.create!({ name:, kind: recipe.kind, engine: recipe.engine, graph_json: recipe.to_json_text }.merge(attrs))
  end
end

# frozen_string_literal: true

module Agent
  # Saves an agent's `inventory` message: the raw lists plus one BackendModel row per file.
  module InventoryStore
    module_function

    def store!(backend, message)
      models = message['models'].is_a?(Hash) ? message['models'] : {}
      BackendInventory.transaction do
        inventory = BackendInventory.find_or_initialize_by(backend_id: backend.id)
        inventory.update!(inventory_hash: message['hash'].to_s, models_json: models,
                          node_types_json: Array(message['node_types']),
                          object_info_hash: message['object_info_hash'],
                          engines_json: engines(message))
        replace_models!(backend, models)
      end
    end

    # Agents older than the engines field run ComfyUI only. A reported empty map means nothing is available.
    def engines(message)
      engines = message['engines']
      engines.is_a?(Hash) ? engines : { 'comfyui' => {} }
    end

    def replace_models!(backend, models)
      BackendModel.where(backend_id: backend.id).delete_all
      now = Time.current
      rows = models.flat_map do |folder, names|
        Array(names).uniq.map { { backend_id: backend.id, folder:, filename: it, created_at: now, updated_at: now } }
      end
      rows.each_slice(5_000) { BackendModel.insert_all(it) } # rubocop:disable Rails/SkipsModelValidations
    end
  end
end

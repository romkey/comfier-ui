# frozen_string_literal: true

module Agent
  # Reassembles chunked `object_info` messages. Chunks wait in the store (not the database) until
  # every index for the hash has arrived; then the gzipped JSON is verified and saved.
  module ObjectInfoStore
    CHUNK_TTL = 10.minutes
    MAX_BYTES = 64.megabytes

    module_function

    def receive_chunk!(backend, message)
      hash = message['hash'].to_s
      count = message['count'].to_i
      key = "object_info:#{backend.id}:#{hash}"
      chunks = Store.read_json(key) || {}
      chunks[message['index'].to_s] = message['data']
      return Store.write_json(key, chunks, ttl: CHUNK_TTL) if chunks.size < count

      Store.delete(key)
      save!(backend, hash, (0...count).map { chunks[it.to_s].to_s }.join)
    end

    def save!(backend, hash, encoded)
      gz = Base64.strict_decode64(encoded)
      json = ActiveSupport::Gzip.decompress(gz)
      raise ArgumentError, 'object_info too large' if json.bytesize > MAX_BYTES

      data = JSON.parse(json)
      record = BackendObjectInfo.find_or_initialize_by(backend_id: backend.id)
      record.update!(object_info_hash: hash, blob_gz: gz)
      sync_node_types!(backend, data.keys)
      RecomputeAvailabilityJob.perform_later(backend_id: backend.id)
      record
    rescue ArgumentError, Zlib::Error, JSON::ParserError => e
      Rails.logger.warn("[Agent] discarded object_info from backend #{backend.id}: #{e.message}")
      nil
    end

    # The option list for a list-typed input (ComfyUI's `["a", "b"]` or `["COMBO", {options: [...]}]`),
    # or nil when the input isn't a list.
    def sync_node_types!(backend, keys)
      inventory = BackendInventory.find_by(backend_id: backend.id)
      return unless inventory

      merged = (Array(inventory.node_types_json) + keys).map(&:to_s).uniq.sort
      return if merged == Array(inventory.node_types_json).map(&:to_s).sort

      inventory.update!(node_types_json: merged)
    end

    def options_for(object_info, class_type, input)
      spec = object_info.dig(class_type, 'input', 'required', input) ||
             object_info.dig(class_type, 'input', 'optional', input)
      return unless spec.is_a?(Array)

      first = spec.first
      return first if first.is_a?(Array)

      Array(spec[1]&.dig('options')) if first == 'COMBO' && spec[1].is_a?(Hash)
    end
  end
end

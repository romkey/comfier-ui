# frozen_string_literal: true

module Agent
  # Handles validated inbound agent messages. Runs in the web process that holds the socket.
  class MessageHandler # rubocop:disable Metrics/ClassLength
    STATUS_PERSIST_EVERY = 30.seconds

    JOB_EVENTS = {
      'job.accepted' => :accepted!, 'job.rejected' => :rejected!, 'job.progress' => :progress!,
      'job.completed' => :completed!, 'job.failed' => :failed!, 'job.cancelled' => :cancelled!
    }.freeze
    DOWNLOAD_EVENTS = {
      'model.download.progress' => :progress!, 'model.download.completed' => :completed!,
      'model.download.failed' => :failed!, 'model.download.cancelled' => :cancelled!
    }.freeze

    def initialize(backend)
      @backend = backend
    end

    def call(message)
      type = message['type']
      @backend.reload
      if (event = JOB_EVENTS[type]) then JobLifecycle.public_send(event, @backend, message)
      elsif (event = DOWNLOAD_EVENTS[type]) then DownloadLifecycle.public_send(event, @backend, message)
      else dispatch_other(type, message)
      end
    end

    HANDLERS = {
      'hello' => :handle_hello, 'inventory' => :handle_inventory, 'object_info' => :handle_object_info,
      'status' => :handle_status, 'job.request' => :handle_job_request, 'bye' => :handle_bye
    }.freeze

    private

    def dispatch_other(type, message)
      handler = HANDLERS[type]
      return Rails.logger.info("[Agent] ignored #{type} from backend #{@backend.id}") unless handler

      send(handler, message)
    end

    def handle_object_info(message) = ObjectInfoStore.receive_chunk!(@backend, message)

    def handle_bye(message) = Presence.mark_offline!(@backend, reason: message['reason'].presence || 'shutdown')

    def handle_hello(message)
      gpu = primary_gpu(message)
      @backend.update!(
        agent_version: message['agent_version'], comfyui_version: message['comfyui_version'],
        system_json: hello_system_json(message), model_downloads_enabled: message['model_downloads_enabled'] == true,
        gpu_name: gpu&.dig('name'), vram_total: gpu && (gpu['vram_total_bytes'] || gpu['vram_total']),
        last_seen_at: Time.current, connected_at: Time.current, offline_since: nil, offline_reason: nil
      )
      Presence.record_hello!(@backend, message)
      OpenRequest.clear(@backend.id)
      Speeds.inherit!(@backend)
      Reconciliation.on_hello!(@backend, message)
      push_pause_state
      Presence.publish!(@backend, force: true)
    end

    def hello_system_json(message)
      download_settings = {
        'max_concurrent' => message['max_concurrent_downloads'],
        'use_hf_cli' => message['use_hf_cli']
      }.compact
      system = (message['system'] || {}).deep_dup
      system['model_download'] = download_settings if download_settings.any?
      system
    end

    def primary_gpu(message)
      devices = Array(message.dig('system', 'devices')).grep(Hash)
      devices.find { it['type'].to_s.match?(/cuda|rocm|mps|xpu/i) } || devices.first
    end

    def push_pause_state
      Commands.send_message(@backend.id, { 'type' => 'config.pause' }) if @backend.paused?
    end

    def handle_inventory(message)
      inventory = @backend.backend_inventory
      changed = inventory.nil? || inventory.inventory_hash != message['hash']
      InventoryStore.store!(@backend, message) if changed
      request_object_info(message['object_info_hash'])
      return unless changed

      RecomputeAvailabilityJob.perform_later(backend_id: @backend.id)
      Presence.publish!(@backend)
    end

    def request_object_info(hash)
      return if hash.blank? || BackendObjectInfo.exists?(backend_id: @backend.id, object_info_hash: hash)
      return unless Store.once_per?("object_info_requested:#{@backend.id}:#{hash}", ttl: 60)

      Commands.send_message(@backend.id, { 'type' => 'object_info.request' })
    end

    def handle_status(message)
      previous = Presence.status(@backend)
      Presence.record_status!(@backend, message)
      message['accepting'] == false ? OpenRequest.clear(@backend.id) : OpenRequest.refresh(@backend.id)
      persist_status!(message)
      LoadMinute.record!(@backend, message, previous:)
      Warmth.note_status!(@backend, message)
      track_local_use!(message, previous)
      update_job_progress!(message)
      Timeline.schedule(@backend)
      Presence.publish!(@backend)
    end

    def persist_status!(message)
      attrs = { last_seen_at: Time.current }
      if @backend.last_status_persisted_at.nil? || @backend.last_status_persisted_at <= STATUS_PERSIST_EVERY.ago
        attrs[:last_status_json] = message
        attrs[:last_status_persisted_at] = Time.current
      end
      @backend.update_columns(attrs) # rubocop:disable Rails/SkipsModelValidations
    end

    def track_local_use!(message, previous)
      now_local = message['state'] == 'busy_local'
      was_local = previous&.dig('state') == 'busy_local'
      if now_local && !was_local
        Store.write_json("busy_local_since:#{@backend.id}", { 'at' => Time.current.to_f }, ttl: 1.day)
      elsif was_local && !now_local
        Speeds.record_local_use!(@backend, Store.read_json("busy_local_since:#{@backend.id}"))
      end
    end

    def update_job_progress!(message)
      Array(message['comfier_jobs']).each do |job|
        id = GenerationAgent.id_from_job_id(job['job_id'])
        next unless id

        Generation.where(id:, backend_id: @backend.id, agent_state: %w[accepted running uploading])
                  .update_all(agent_progress: job['progress'].to_f, current_node: job['node']) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    def handle_job_request(message)
      OpenRequest.set(@backend.id, message['request_id'])
      Dispatcher.dispatch_for!(@backend, request_id: message['request_id'])
    end
  end
end

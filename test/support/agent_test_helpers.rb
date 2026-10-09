# frozen_string_literal: true

module AgentTestHelpers
  # Stands in for a WebSocket. Every message the frontend sends is checked against the protocol
  # schema, so a test fails if any code path builds an invalid message.
  class FakeSocket
    attr_reader :sent, :close_code, :close_reason

    def initialize
      @sent = []
    end

    def send(payload)
      message = payload.is_a?(String) ? JSON.parse(payload) : payload
      errors = Agent::ProtocolValidator.errors_for(message)
      raise "invalid outbound #{message['type']}: #{errors.join('; ')}" if errors.any?

      @sent << message
    end

    def close(code = 1000, reason = nil)
      @close_code = code
      @close_reason = reason
    end

    def closed? = !@close_code.nil?
    def of_type(type) = @sent.select { it['type'] == type }
    def last_of_type(type) = of_type(type).last
    def clear! = @sent.clear
  end

  def self.included(base)
    base.setup { reset_agent_state! }
  end

  def reset_agent_state!
    Agent::Store.reset!
    Agent::Hub.reset!
    Agent::CommandSubscriber.reset!
  end

  # Registers a socket the way the WebSocket app does on open.
  def connect_agent!(backend)
    socket = FakeSocket.new
    Agent::Hub.instance.connect!(backend, socket)
    Agent::Presence.record_connected!(backend)
    socket
  end

  def agent_message(backend, message)
    message = message.deep_stringify_keys
    Agent::ProtocolValidator.validate_inbound!(message)
    Agent::MessageHandler.new(backend).call(message)
  end

  def agent_hello(backend, socket = nil, **extra)
    agent_message(backend, {
      'type' => 'hello', 'protocol' => 1, 'agent_version' => '1.0.0', 'backend_name' => backend.name,
      'comfyui_version' => '0.3.60', 'model_downloads_enabled' => true, 'active_jobs' => [], 'active_downloads' => [],
      'system' => { 'devices' => [{ 'name' => 'NVIDIA RTX 4090', 'type' => 'cuda', 'vram_total' => 24.gigabytes }] }
    }.merge(extra.deep_stringify_keys))
    socket
  end

  # extra: object_info_hash:, engines: ({ mflux: { models: [...] } })
  def agent_inventory(backend, models: {}, node_types: [], hash: nil, **extra)
    models = models.transform_keys(&:to_s)
    engines = extra[:engines]&.deep_stringify_keys
    message = { 'type' => 'inventory', 'models' => models, 'node_types' => node_types,
                'hash' => hash || Digest::SHA256.hexdigest([models, node_types, engines].to_json) }
    message['object_info_hash'] = extra[:object_info_hash] if extra[:object_info_hash]
    message['engines'] = engines if engines
    agent_message(backend, message)
  end

  def agent_status(backend, state: 'idle', accepting: true, **extra)
    agent_message(backend, { 'type' => 'status', 'state' => state, 'accepting' => accepting,
                             'comfier_jobs' => [] }.merge(extra.deep_stringify_keys))
  end

  def agent_request(backend, request_id = "r_#{SecureRandom.hex(3)}")
    agent_message(backend, { 'type' => 'job.request', 'request_id' => request_id })
    request_id
  end

  # hello, inventory and status: a connected, accepting server.
  def bring_online!(backend, models: {}, node_types: [], **status)
    socket = connect_agent!(backend)
    agent_hello(backend)
    agent_inventory(backend, models:, node_types:)
    agent_status(backend, **status)
    socket
  end

  # Everything `workflow` needs, as inventory arguments.
  def inventory_for(*workflows)
    requirements = workflows.map { Agent::Requirements.for(it) }
    models = requirements.flat_map(&:models).group_by { it['folder'] }.transform_values { |ms| ms.pluck('filename') }
    { models:, node_types: requirements.flat_map(&:node_types).uniq }
  end

  def set_model_links(workflow, **attrs)
    Agent::Requirements.for(workflow)
    workflow.workflow_models.update_all(attrs) # rubocop:disable Rails/SkipsModelValidations
  end

  def bring_online_for!(backend, *workflows, **) = bring_online!(backend, **inventory_for(*workflows), **)

  def create_agent_backend!(owner:, name: 'Agent box', **attrs)
    Backend.create!({ name:, connection_kind: 'agent', owner_user: owner, visibility: 'private', enabled: true,
                      model_downloads_enabled: true }.merge(attrs))
  end

  def create_agent_key!(backend) = backend.issue_agent_key!

  # 1.0 is typical, 2.0 twice as slow.
  def set_speed(backend, speed_index)
    BackendSpeed.find_or_initialize_by(backend_id: backend.id).update!(speed_index:)
    backend.reload
  end

  # A minimal enabled image workflow whose only model is one checkpoint.
  def create_agent_workflow!(name: 'Agent style', checkpoint: 'sdxl.safetensors', url: nil, extra: {})
    graph = {
      '1' => { 'class_type' => 'CheckpointLoaderSimple', 'inputs' => { 'ckpt_name' => checkpoint } },
      '2' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'text' => '{{prompt}}', 'clip' => ['1', 1] } },
      '3' => { 'class_type' => 'SaveImage', 'inputs' => { 'images' => ['2', 0] } }
    }.merge(extra)
    workflow = Workflow.create!(name:, kind: 'image', graph:, enabled: true)
    if url
      workflow.workflow_models.find_by(filename: checkpoint)&.update!(url:, bytes: 1.gigabyte, source: 'admin')
      Agent::Requirements.extract!(workflow)
    end
    workflow
  end

  def create_agent_generation!(user:, workflow:, prompt: 'a lighthouse', **attrs)
    Generation.create!({ user:, workflow:, prompt:, kind: workflow.kind }.merge(attrs))
  end

  def submit_agent_generation!(user:, workflow:, **)
    generation = create_agent_generation!(user:, workflow:, **)
    Agent::Submission.enqueue!(generation)
    generation.reload
  end

  def job_id(generation) = "j_#{generation.id}"
end

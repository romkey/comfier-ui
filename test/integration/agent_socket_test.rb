require 'test_helper'
require 'puma'
require 'puma/server'
require 'faye/websocket'

# A fake agent over a real WebSocket against the app running in Puma: authentication, the hello
# handshake, limits, replacement, revocation, and a job from request to completion.
class AgentSocketTest < ActionDispatch::IntegrationTest
  WAIT = 5

  # A WebSocket client whose events land in queues the test can wait on.
  class Client
    attr_reader :messages, :close_event

    def initialize(url, token)
      @messages = Queue.new
      @closed = Queue.new
      EM.next_tick do
        headers = token ? { 'Authorization' => "Bearer #{token}" } : {}
        @ws = Faye::WebSocket::Client.new(url, nil, headers:)
        @ws.on(:message) { |event| @messages << JSON.parse(event.data) }
        @ws.on(:close) { |event| @closed << [event.code, event.reason] }
      end
    end

    def send_json(message) = EM.next_tick { @ws.send(message.is_a?(String) ? message : JSON.generate(message)) }

    def next_message(type, timeout: WAIT)
      deadline = Time.current + timeout
      loop do
        remaining = deadline - Time.current
        raise "no #{type} within #{timeout}s" unless remaining.positive?

        message = @messages.pop(timeout: remaining)
        return message if message && message['type'] == type
      end
    end

    def wait_closed(timeout: WAIT)
      @wait_closed ||= @closed.pop(timeout:) || raise("not closed within #{timeout}s")
    end

    def close = EM.next_tick { @ws&.close }
  end

  def self.port
    @port ||= begin
      server = Puma::Server.new(Rails.application, nil, min_threads: 0, max_threads: 4, log_writer: Puma::LogWriter.null)
      server.add_tcp_listener('127.0.0.1', 0)
      server.run
      server.connected_ports.first
    end
  end

  setup do
    Thread.new { EM.run } unless EM.reactor_running?
    sleep 0.01 until EM.reactor_running?
    @alice = users(:alice)
    @backend = create_agent_backend!(owner: @alice)
    @token = create_agent_key!(@backend)
    @clients = []
  end

  # The reactor may still be handling the last message with this test's database connection.
  teardown do
    @clients.each(&:close)
    drained = Queue.new
    EM.add_timer(0.1) { drained << true }
    drained.pop(timeout: WAIT)
  end

  def connect(token = @token)
    Client.new("ws://127.0.0.1:#{self.class.port}/api/agent/ws", token).tap { @clients << it }
  end

  def hello(client, protocol: 1)
    client.send_json(type: 'hello', protocol:, agent_version: '1.0.0', backend_name: 'Box',
                     model_downloads_enabled: true, active_jobs: [], active_downloads: [],
                     system: { devices: [{ name: 'NVIDIA RTX 4090', type: 'cuda', vram_total: 24.gigabytes }] })
  end

  def wait_until(timeout: WAIT)
    deadline = Time.current + timeout
    sleep 0.02 until yield || Time.current > deadline

    assert yield, 'condition not met in time'
  end

  test 'a bad key is refused before the upgrade' do
    code, reason = connect('cmf_wrong').wait_closed

    assert_equal 1002, code
    assert_match '401', reason
  end

  test 'the first message must be hello' do
    client = connect
    client.send_json(type: 'status', state: 'idle', accepting: true)

    assert_equal 1008, client.wait_closed.first
  end

  test 'another protocol version is refused with 4426' do
    client = connect
    hello(client, protocol: 2)

    assert_equal 4426, client.wait_closed.first
  end

  test 'a server that never says hello is disconnected' do
    silence_warnings { AgentTiming.const_set(:HELLO_TIMEOUT_S, 0.3) }
    client = connect

    assert_equal [1008, 'hello timeout'], client.wait_closed
  ensure
    silence_warnings { AgentTiming.const_set(:HELLO_TIMEOUT_S, 10) }
  end

  test 'oversized messages close with 1009' do
    client = connect
    hello(client)
    client.send_json({ type: 'status', state: 'idle', accepting: true,
                       pad: 'x' * (AgentTiming::MAX_MESSAGE_BYTES + 10) }.to_json)

    assert_equal 1009, client.wait_closed.first
  end

  test 'flooding closes with 1008' do
    client = connect
    hello(client)
    (AgentTiming::MAX_MESSAGES_PER_SECOND + 10).times { client.send_json(type: 'status', state: 'idle', accepting: true) }

    assert_equal [1008, 'rate limit'], client.wait_closed
  end

  test 'a second connection replaces the first with 4409' do
    first = connect
    hello(first)
    wait_until { Agent::Presence.hello(@backend).present? }
    second = connect
    hello(second)

    assert_equal 4409, first.wait_closed.first
    wait_until { Agent::Presence.connected?(@backend) }
  end

  test 'revoking the key disconnects with 4401' do
    client = connect
    hello(client)
    wait_until { Agent::Presence.hello(@backend).present? }
    Agent::KeyRotation.revoke!(@backend.backend_keys.first)

    assert_equal 4401, client.wait_closed.first
  end

  test 'a job goes from request to completed over the socket' do
    workflow = workflows(:sd_image)
    requirements = inventory_for(workflow)
    gen = Generation.create!(user: @alice, workflow:, prompt: 'socket', kind: :image, status: :queued,
                             backend: @backend, agent_state: 'queued', filled_workflow_json: { '1' => {} },
                             queued_at: Time.current, queue_order: 1)
    client = connect
    hello(client)
    client.send_json(type: 'inventory', hash: 'h1', models: requirements[:models],
                     node_types: requirements[:node_types])
    client.send_json(type: 'status', state: 'idle', accepting: true, comfier_jobs: [])
    client.send_json(type: 'job.request', request_id: 'r_1')

    assign = client.next_message('job.assign')

    assert_equal "j_#{gen.id}", assign['job_id']
    assert_equal 'r_1', assign['request_id']

    client.send_json(type: 'job.accepted', job_id: assign['job_id'])
    output = gen.generation_outputs.create!(upload_id: 'u_socket', backend: @backend, node: '9', filename: 'out.png',
                                            kind: 'image', bytes: 1)
    client.send_json(type: 'job.completed', job_id: assign['job_id'], outputs: [{ upload_id: output.upload_id }],
                     timings: { execute_ms: 1000 })
    wait_until { gen.reload.succeeded? }

    assert_equal 'completed', gen.agent_state
  end

  test 'closing marks the server disconnected' do
    client = connect
    hello(client)
    client.send_json(type: 'status', state: 'idle', accepting: true)
    wait_until { Agent::Presence.online?(@backend) }
    client.close
    wait_until { !Agent::Presence.connected?(@backend) }
  end
end

# frozen_string_literal: true

require 'faye/websocket'

module Agent
  # Rack app for GET /api/agent/ws (Comfier Agent protocol v1). Authenticates before upgrading,
  # then hands each message to Agent::MessageHandler.
  class WebsocketApp
    CLOSE_PROTOCOL = 4426
    CLOSE_TOO_BIG = 1009
    CLOSE_POLICY = 1008

    def self.call(env) = new.call(env)

    def call(env)
      request = Rack::Request.new(env)
      return unauthorized unless Faye::WebSocket.websocket?(env)

      backend = authenticate(request)
      return unauthorized unless backend&.agent? && backend.deleted_at.nil?

      open_socket(env, backend)
    end

    private

    def authenticate(request)
      Rails.application.executor.wrap do
        Authenticator.from_header(request.get_header('HTTP_AUTHORIZATION'), ip: request.ip).backend
      end
    rescue Authenticator::AuthenticationError
      nil
    end

    def open_socket(env, backend)
      ws = Faye::WebSocket.new(env, nil, ping: AgentTiming::HEARTBEAT_S, max_length: AgentTiming::MAX_MESSAGE_BYTES * 2)
      adapter = SocketAdapter.new(ws)
      inbound = Inbound.new(backend, adapter)
      ws.on(:open) { inbound.opened }
      ws.on(:message) { |event| inbound.receive(event.data) }
      ws.on(:close) { inbound.closed }
      ws.rack_response
    end

    def unauthorized = [401, { 'content-type' => 'text/plain' }, ['Unauthorized']]

    # Wraps a Faye socket so writes from other threads are scheduled on the EventMachine reactor.
    class SocketAdapter
      def initialize(socket) = @ws = socket

      def send(payload)
        text = payload.is_a?(String) ? payload : JSON.generate(payload)
        on_reactor { @ws.send(text) }
      end

      # Faye's API only allows 1000 and 3000-4999; the protocol also uses 1008 and 1009, which the
      # underlying driver sends fine.
      def close(code = 1000, reason = nil)
        on_reactor do
          driver = @ws.instance_variable_get(:@driver)
          if code == 1000 || (3000..4999).cover?(code) || driver.nil?
            @ws.close(code, reason)
          else
            driver.close(reason.to_s, code)
          end
        end
      end

      private

      def on_reactor(&)
        if defined?(EM) && EM.reactor_running? && !EM.reactor_thread?
          EM.next_tick(&)
        else
          yield
        end
      end
    end

    # One connection's inbound side: hello handshake, limits, and message handling.
    class Inbound
      def initialize(backend, adapter, handler: MessageHandler.new(backend))
        @backend = backend
        @adapter = adapter
        @handler = handler
        @hello_ok = false
        @rate_limiter = RateLimiter.new
      end

      def opened
        wrap do
          Hub.instance.connect!(@backend, @adapter)
          Presence.record_connected!(@backend)
          @backend.update_columns(connected_at: Time.current, offline_since: nil, offline_reason: nil) # rubocop:disable Rails/SkipsModelValidations
        end
        CommandSubscriber.ensure_started!
        start_hello_timer
      end

      def receive(raw)
        return if @closing
        return close(CLOSE_TOO_BIG, 'message too big') if raw.to_s.bytesize > AgentTiming::MAX_MESSAGE_BYTES
        return close(CLOSE_POLICY, 'rate limit') unless @rate_limiter.allowed?

        @rate_limiter.handling do
          message = JSON.parse(raw)
          next unless handshake_ok?(message)

          wrap { handle(message) }
        end
      rescue JSON::ParserError
        Rails.logger.warn("[Agent] invalid JSON from backend #{@backend.id}")
      rescue StandardError => e
        # Handlers run on the EventMachine reactor that every agent socket shares.
        Rails.logger.error("[Agent] #{e.class} handling a message from backend #{@backend.id}: #{e.message}")
        Rails.error.report(e, handled: true)
      end

      def closed
        @closed = true
        wrap do
          next unless Hub.instance.disconnect!(@backend.id, @adapter)

          Presence.record_disconnected!(@backend)
          Presence.publish!(@backend, force: true)
        end
      end

      def hello_received? = @hello_ok

      private

      def handshake_ok?(message)
        return true if @hello_ok

        code, reason = handshake_error(message)
        return @hello_ok = true unless code

        close(code, reason)
        false
      end

      def handshake_error(message)
        return [CLOSE_POLICY, 'expected hello'] unless message.is_a?(Hash) && message['type'] == 'hello'

        [CLOSE_PROTOCOL, 'unsupported protocol'] unless message['protocol'] == 1
      end

      def handle(message)
        return if ProtocolValidator.validate_inbound!(message) == :unknown

        @handler.call(message)
      rescue ProtocolValidator::ValidationError => e
        Rails.logger.warn("[Agent] dropped #{message['type']} from backend #{@backend.id}: #{e.message}")
      end

      def start_hello_timer
        return unless defined?(EM) && EM.reactor_running?

        EM.add_timer(AgentTiming::HELLO_TIMEOUT_S) do
          close(CLOSE_POLICY, 'hello timeout') unless @hello_ok || @closed
        end
      end

      def close(code, reason)
        @closing = true
        @adapter.close(code, reason)
      end

      def wrap(&) = Rails.application.executor.wrap(&)
    end

    # Messages wait on the reactor while earlier ones are handled, so timing them on the wall clock
    # would spread a burst over however long handling takes, and a flood to a busy server would
    # never trip the limit. The clock here stops while this connection's messages are handled.
    class RateLimiter
      def initialize(limit: AgentTiming::MAX_MESSAGES_PER_SECOND)
        @limit = limit
        @timestamps = []
        @handling_s = 0.0
      end

      def allowed?
        now = clock
        @timestamps.reject! { it < now - 1 }
        return false if @timestamps.size >= @limit

        @timestamps << now
        true
      end

      def handling
        started = monotonic
        yield
      ensure
        @handling_s += monotonic - started
      end

      private

      def clock = monotonic - @handling_s

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

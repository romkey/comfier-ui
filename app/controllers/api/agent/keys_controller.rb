# frozen_string_literal: true

module Api
  module Agent
    # Lets `comfier-agent setup` and `doctor` check a key without opening a WebSocket, which would replace
    # the running agent's connection. Says which server the key belongs to, or why it was refused.
    class KeysController < ActionController::API
      def show
        # Not a use of the key: the agent's last connection time and IP stay as they were.
        result = ::Agent::Authenticator.from_header(request.authorization, touch: false)
        render json: { server: result.backend.name, key: result.backend_key.display }
      rescue ::Agent::Authenticator::AuthenticationError => e
        render json: { error: refusal(e.message) }, status: :unauthorized
      end

      private

      # Revoked and expired are only reported for the key's real secret, so they don't leak anything.
      def refusal(reason)
        case reason
        when 'revoked key' then 'This key was revoked. Create a new one on the server’s page in Comfier.'
        when 'expired key' then 'This key has expired. Create a new one on the server’s page in Comfier.'
        when 'server deleted' then 'The server this key belongs to was deleted.'
        else 'Comfier doesn’t recognize this key. Copy it again from the server’s page.'
        end
      end
    end
  end
end

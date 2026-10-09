# frozen_string_literal: true

module Agent
  # Resolves `Authorization: Bearer cmf_…` to a backend. Keys only work on /api/agent/*.
  # Rejections of a known prefix are recorded so the setup page can explain them.
  class Authenticator
    Result = Data.define(:backend, :backend_key)

    class AuthenticationError < StandardError; end

    # touch: false checks the key without recording a use (the key check `comfier-agent setup` makes).
    def self.from_header(authorization, ip: nil, touch: true) = new(authorization, ip:, touch:).authenticate!

    def initialize(authorization, ip: nil, touch: true)
      @authorization = authorization.to_s
      @ip = ip
      @touch = touch
    end

    def authenticate!
      key = matching_key
      reject!(key, 'revoked') if key.revoked?
      reject!(key, 'expired') if key.expired?
      raise AuthenticationError, 'server deleted' if key.backend.deleted_at

      key.touch_used!(ip: @ip) if @touch
      Result.new(backend: key.backend, backend_key: key)
    end

    private

    def matching_key
      token = bearer_token
      raise AuthenticationError, 'missing token' unless token&.start_with?(KeyService::PREFIX)

      key = BackendKey.includes(:backend).find_by(prefix: KeyService.prefix_of(token))
      raise AuthenticationError, 'unknown key' unless key
      raise AuthenticationError, 'invalid key' unless KeyService.matches?(token, key.key_hash)

      key
    end

    def reject!(key, reason)
      key.update_columns(last_rejected_at: Time.current, last_rejected_reason: reason) # rubocop:disable Rails/SkipsModelValidations
      raise AuthenticationError, "#{reason} key"
    end

    def bearer_token
      @authorization[/\ABearer\s+(\S+)\z/i, 1]
    end
  end
end

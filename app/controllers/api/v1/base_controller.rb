module Api
  module V1
    class BaseController < ActionController::API
      before_action :prevent_caching
      before_action :authenticate_token!
      before_action :require_privacy_acceptance!

      rescue_from ActiveRecord::RecordNotFound do
        render_error(:not_found, 'not_found', 'Resource not found.')
      end
      rescue_from ActionController::ParameterMissing, ActionController::BadRequest,
                  ActionDispatch::Http::Parameters::ParseError do |error|
        render_error(:bad_request, 'invalid_request', error.message)
      end
      rescue_from ActiveRecord::RecordInvalid do |error|
        render_error(:unprocessable_content, 'validation_failed', 'Generation is invalid.',
                     details: error.record.errors.to_hash)
      end

      private

      attr_reader :current_user

      def prevent_caching
        response.headers['Cache-Control'] = 'no-store'
      end

      def authenticate_token!
        raw = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
        token = PersonalApiToken.authenticate(raw)
        unless token
          response.headers['WWW-Authenticate'] = 'Bearer'
          return render_error(:unauthorized, 'invalid_token', 'A valid personal API token is required.')
        end

        token.update!(last_used_at: Time.current)
        @current_user = token.user
      end

      def require_privacy_acceptance!
        return if current_user.privacy_current?

        render_error(:forbidden, 'privacy_acceptance_required',
                     'Accept the current Code of Conduct and privacy notice in the web app before using the API.')
      end

      def render_error(status, code, message, **extra)
        render json: { error: { code:, message:, **extra } }, status:
      end
    end
  end
end

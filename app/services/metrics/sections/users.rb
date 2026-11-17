module Metrics
  module Sections
    class Users < Base
      def collect
        admins = User.where(admin: true).count
        gauge('comfier_users', 'User accounts, by role.',
              [[{ role: 'admin' }, admins], [{ role: 'user' }, User.count - admins]])
        gauge('comfier_users_signed_in', 'Users who last signed in within the window.',
              windowed { User.where(last_signed_in_at: it..).count })
        gauge('comfier_users_generating', 'Users who started at least one generation within the window.',
              windowed { Generation.where(created_at: it..).distinct.count(:user_id) })
        gauge('comfier_users_chatting', 'Users with a chat that was active within the window.',
              windowed { ChatConversation.where(updated_at: it..).distinct.count(:user_id) })
        tokens
      end

      private

      def tokens
        gauge('comfier_api_tokens', 'Personal API tokens that exist.', PersonalApiToken.count)
        gauge('comfier_api_tokens_used', 'Personal API tokens used within the window.',
              windowed { PersonalApiToken.where(last_used_at: it..).count })
      end
    end
  end
end

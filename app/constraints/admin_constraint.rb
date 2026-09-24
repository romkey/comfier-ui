# Lets only signed-in admins reach mounted engines such as the Sidekiq dashboard.
module AdminConstraint
  def self.matches?(request)
    user_id = request.session[:user_id]
    user_id.present? && User.exists?(id: user_id, admin: true)
  end
end

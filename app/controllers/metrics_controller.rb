# Metrics for Prometheus, in its text format. Off (404) until METRICS_TOKEN is set; then every request must
# send that token as a bearer token. See docs/METRICS.md.
class MetricsController < ActionController::API
  before_action :require_configured
  before_action :authenticate

  def show
    response.headers['Cache-Control'] = 'no-store'
    render plain: Metrics::Collector.render, content_type: Metrics::Registry::CONTENT_TYPE
  end

  private

  def token = ENV['METRICS_TOKEN'].to_s.strip.presence

  def require_configured
    head :not_found unless token
  end

  def authenticate
    given = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1].to_s
    return if ActiveSupport::SecurityUtils.secure_compare(given, token)

    response.headers['WWW-Authenticate'] = 'Bearer realm="metrics"'
    head :unauthorized
  end
end

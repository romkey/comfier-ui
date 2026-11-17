require 'test_helper'

class MetricsTest < ActionDispatch::IntegrationTest
  TOKEN = 'scrape-secret-for-tests'.freeze

  def scrape(token = TOKEN)
    headers = token ? { 'Authorization' => "Bearer #{token}" } : {}
    with_env('METRICS_TOKEN' => TOKEN) { get metrics_path, headers: }
  end

  test 'the endpoint does not exist until a token is configured' do
    with_env('METRICS_TOKEN' => nil) { get metrics_path, headers: { 'Authorization' => 'Bearer anything' } }

    assert_response :not_found
    assert_empty response.body
  end

  test 'a blank token leaves the endpoint off' do
    with_env('METRICS_TOKEN' => '  ') { get metrics_path, headers: { 'Authorization' => 'Bearer ' } }

    assert_response :not_found
  end

  test 'a request without a token is refused' do
    scrape(nil)

    assert_response :unauthorized
    assert_equal 'Bearer realm="metrics"', response.headers['WWW-Authenticate']
    assert_empty response.body
  end

  test 'a wrong token is refused' do
    scrape('not-the-token')

    assert_response :unauthorized
  end

  test 'the token is not accepted as a query parameter or with another scheme' do
    with_env('METRICS_TOKEN' => TOKEN) do
      get metrics_path, params: { token: TOKEN }

      assert_response :unauthorized

      get metrics_path, headers: { 'Authorization' => "Basic #{TOKEN}" }

      assert_response :unauthorized
    end
  end

  test 'a signed-in session does not stand in for the token' do
    OmniAuth.config.mock_auth[:authentik] = auth_hash(uid: 'admin-uid', groups: [User.admin_group])
    get auth_callback_path(:authentik)
    scrape(nil)

    assert_response :unauthorized
  end

  test 'the right token gets the metrics as Prometheus text' do
    scrape

    assert_response :success
    assert_equal 'text/plain; version=0.0.4; charset=utf-8', response.headers['Content-Type']
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_includes response.body, "# TYPE comfier_generations gauge\n"
    assert_includes response.body, 'comfier_generations{kind="image",status="succeeded"}'
    assert_includes response.body, 'comfier_users{role="admin"} 1'
    assert_includes response.body, 'comfier_server_up{server="GPU box"} 1'
    assert_includes response.body, 'comfier_scrape_section_errors{section="generations"} 0'
  end

  test 'every line is valid exposition format' do
    scrape

    sample = /\A[a-z_][a-z0-9_]*(\{([a-z_]+="(\\.|[^"\\])*",?)+\})? (-?\d+(\.\d+)?(e-?\d+)?|NaN|[+-]Inf)\z/
    bad = response.body.lines(chomp: true).reject { it.start_with?('# HELP ', '# TYPE ') || it.match?(sample) }

    assert_empty bad
  end
end

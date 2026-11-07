require 'test_helper'

class UserApiTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:alice)
    @token, @secret = PersonalApiToken.issue!(user: @user, name: 'Integration')
    @headers = { 'Authorization' => "Bearer #{@secret}" }
  end

  test 'requires personal bearer authentication rather than a browser session or agent key' do
    sign_in_as @user
    [nil, 'Bearer cmf_agent-secret', 'Bearer invalid'].each do |authorization|
      get '/api/v1/workflows', headers: { 'Authorization' => authorization }

      assert_response :unauthorized
      assert_equal 'invalid_token', response.parsed_body.dig('error', 'code')
    end
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'revoked tokens stop working immediately' do
    @token.revoke!
    get '/api/v1/workflows', headers: @headers

    assert_response :unauthorized
  end

  test 'requires acceptance of current privacy notice without redirecting' do
    @user.update!(privacy_accepted_version: nil)
    get '/api/v1/workflows', headers: @headers

    assert_response :forbidden
    assert_equal 'privacy_acceptance_required', response.parsed_body.dig('error', 'code')
  end

  test 'lists enabled workflows and supported user inputs without exposing graphs' do
    get '/api/v1/workflows', headers: @headers

    assert_response :success
    workflows_json = response.parsed_body.fetch('workflows')

    assert_not_includes workflows_json.pluck('id'), workflows(:retired_image).id
    workflow = workflows_json.find { |item| item['id'] == workflows(:sd_image).id }

    assert workflow.dig('inputs', 'prompt', 'required')
    assert_equal Generation::ASPECT_RATIOS, workflow.dig('inputs', 'aspect_ratio', 'enum')
    assert_not workflow.key?('graph')
  end

  test 'submits with existing parameter resolution and queues asynchronously' do
    assert_difference('Generation.count', 1) do
      assert_enqueued_with(job: SubmitGenerationJob) do
        submit(workflow_id: workflows(:sd_image).id, prompt: 'A fox', aspect_ratio: '4:3', seed: 42)
      end
    end
    assert_response :created
    generation = @user.generations.recent.first

    assert_equal generation.id, response.parsed_body.dig('generation', 'id')
    assert_equal 'queued', response.parsed_body.dig('generation', 'status')
    assert_equal 42, generation.seed
    assert_equal '4:3', generation.aspect_ratio
    assert_equal "http://www.example.com/api/v1/generations/#{generation.id}", response.headers['Location']
  end

  test 'accepts multipart reference image uploads' do
    attributes = { workflow_id: workflows(:image_to_3d).id, input_image: png_upload }
    post '/api/v1/generations', headers: @headers, params: { generation: attributes }

    assert_response :created
    assert_predicate @user.generations.recent.first.input_image, :attached?
  end

  test 'rejects disabled workflows and invalid prompts without submitting work' do
    assert_no_difference('Generation.count') do
      assert_no_enqueued_jobs(only: SubmitGenerationJob) do
        submit(workflow_id: workflows(:retired_image).id, prompt: 'A fox')

        assert_response :unprocessable_content
        assert_equal 'validation_failed', response.parsed_body.dig('error', 'code')
        submit(workflow_id: workflows(:sd_image).id, prompt: '')

        assert_response :unprocessable_content
        assert_predicate response.parsed_body.dig('error', 'details', 'prompt'), :present?
      end
    end
  end

  test 'bad request bodies and pagination return JSON errors' do
    post '/api/v1/generations', params: {}, headers: @headers, as: :json

    assert_response :bad_request
    assert_equal 'invalid_request', response.parsed_body.dig('error', 'code')
    get '/api/v1/generations', params: { page: -1 }, headers: @headers

    assert_response :bad_request
  end

  test 'rejects JSON attachment references instead of accepting another users signed blob' do
    submit(workflow_id: workflows(:image_to_3d).id, input_image: 'not-a-file')

    assert_response :bad_request
    assert_equal 'invalid_request', response.parsed_body.dig('error', 'code')
  end

  test 'malformed JSON returns an API error' do
    post '/api/v1/generations', params: '{"generation":',
                                headers: @headers.merge('Content-Type' => 'application/json',
                                                        'Accept' => 'application/json')

    assert_response :bad_request
    assert_equal 'invalid_request', response.parsed_body.dig('error', 'code')
  end

  test 'blank and oversized idempotency keys cannot submit generations' do
    assert_no_difference('Generation.count') do
      ['', 'x' * 256].each do |key|
        @headers['Idempotency-Key'] = key
        submit(workflow_id: workflows(:sd_image).id, prompt: 'A fox')

        assert_response :bad_request
        assert_equal 'invalid_request', response.parsed_body.dig('error', 'code')
      end
    end
  end

  test 'authenticated requests update token last use' do
    freeze_time do
      get '/api/v1/workflows', headers: @headers

      assert_response :success
      assert_equal Time.current, @token.reload.last_used_at
    end
  end

  test 'only lists own generations with bounded pagination' do
    get '/api/v1/generations', params: { per_page: 2 }, headers: @headers

    assert_response :success
    body = response.parsed_body

    assert_equal 2, body.fetch('generations').length
    assert_equal 2, body.dig('pagination', 'next_page')
    assert_empty body.fetch('generations').pluck('id') - @user.generations.ids
  end

  test 'reports progress and errors from generation lifecycle' do
    generation = generations(:alice_failed)
    generation.update!(agent_phase: 'denoising', agent_progress: 0.5)
    get "/api/v1/generations/#{generation.id}", headers: @headers

    assert_response :success
    body = response.parsed_body.fetch('generation')

    assert_equal 'failed', body['status']
    assert_equal generation.error_message, body['error']
    assert_equal({ 'phase' => 'denoising', 'fraction' => 0.5 }, body['progress'])
  end

  test 'other users and admin tokens cannot inspect or cancel another users generation' do
    _admin_token, secret = PersonalApiToken.issue!(user: users(:admin), name: 'Admin')
    [@headers, { 'Authorization' => "Bearer #{secret}" }].each do |headers|
      get "/api/v1/generations/#{generations(:bob_done).id}", headers: headers

      assert_response :not_found
      post "/api/v1/generations/#{generations(:bob_done).id}/cancel", headers: headers

      assert_response :not_found
    end
  end

  test 'cancels queued generations through the existing canceller' do
    generation = @user.generations.create!(workflow: workflows(:sd_image), prompt: 'Cancel me')
    post "/api/v1/generations/#{generation.id}/cancel", headers: @headers

    assert_response :success
    assert_equal Generation::CANCELLED_MESSAGE, generation.reload.error_message
    assert_equal 'failed', response.parsed_body.dig('generation', 'status')
  end

  test 'finished generations cannot be cancelled' do
    post "/api/v1/generations/#{generations(:alice_done).id}/cancel", headers: @headers

    assert_response :conflict
    assert_equal 'not_cancellable', response.parsed_body.dig('error', 'code')
  end

  test 'output URLs require the owners bearer token and support downloading' do
    generation = generations(:alice_done)
    generation.outputs.attach(io: StringIO.new(png_bytes), filename: 'fox.png', content_type: 'image/png')
    get "/api/v1/generations/#{generation.id}", headers: @headers
    output = response.parsed_body.dig('generation', 'outputs').first

    assert_equal 'fox.png', output['filename']
    get output['download_url'], headers: @headers

    assert_response :success
    assert_equal png_bytes, response.body
    assert_equal 'no-store', response.headers['Cache-Control']
    get output['download_url']

    assert_response :unauthorized
    _token, secret = PersonalApiToken.issue!(user: users(:bob), name: 'Other')
    get output['download_url'], headers: { 'Authorization' => "Bearer #{secret}" }

    assert_response :not_found
  end

  test 'idempotency replays without creating or enqueueing another job and rejects changed inputs' do
    @headers['Idempotency-Key'] = 'retry-123'
    attributes = { workflow_id: workflows(:sd_image).id, prompt: 'A fox' }
    submit(**attributes)

    assert_response :created
    id = response.parsed_body.dig('generation', 'id')
    assert_no_difference('Generation.count') do
      assert_no_enqueued_jobs(only: SubmitGenerationJob) do
        submit(**attributes)

        assert_response :success
        assert_equal id, response.parsed_body.dig('generation', 'id')
        assert_equal 'true', response.headers['Idempotency-Replayed']
        submit(**attributes, prompt: 'A bear')

        assert_response :conflict
      end
    end
  end

  test 'failed validation does not consume an idempotency key' do
    @headers['Idempotency-Key'] = 'corrected-request'
    submit(workflow_id: workflows(:sd_image).id, prompt: '')

    assert_response :unprocessable_content
    submit(workflow_id: workflows(:sd_image).id, prompt: 'A fox')

    assert_response :created
  end

  test 'idempotency keys are scoped to users and survive deletion of the result' do
    @headers['Idempotency-Key'] = 'same-key'
    attributes = { workflow_id: workflows(:sd_image).id, prompt: 'A fox' }
    submit(**attributes)

    assert_response :created
    generation = @user.generations.find(response.parsed_body.dig('generation', 'id'))
    generation.destroy!
    submit(**attributes)

    assert_response :conflict
    _token, secret = PersonalApiToken.issue!(user: users(:bob), name: 'Other')
    @headers['Authorization'] = "Bearer #{secret}"
    submit(**attributes)

    assert_response :created
  end

  test 'idempotency compares uploaded file contents' do
    @headers['Idempotency-Key'] = 'upload-request'
    attributes = { workflow_id: workflows(:image_to_3d).id }
    post '/api/v1/generations', headers: @headers, params: { generation: attributes.merge(input_image: png_upload) }

    assert_response :created
    post '/api/v1/generations', headers: @headers, params: { generation: attributes.merge(input_image: png_upload) }

    assert_response :success
    changed = Rack::Test::UploadedFile.new(StringIO.new('different'), 'image/png', original_filename: 'pixel.png')
    post '/api/v1/generations', headers: @headers, params: { generation: attributes.merge(input_image: changed) }

    assert_response :conflict
  end

  private

  def submit(**attributes)
    post '/api/v1/generations', params: { generation: attributes }, headers: @headers, as: :json
  end
end

require 'test_helper'

class AgentApiTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @backend = create_agent_backend!(owner: @alice)
    @token = create_agent_key!(@backend)
    @generation = Generation.create!(user: @alice, workflow: workflows(:sd_image), prompt: 'x', kind: :image,
                                     status: :running, backend: @backend, agent_state: 'running', agent_attempt: 1,
                                     filled_workflow_json: {})
  end

  def auth(token = @token) = { 'Authorization' => "Bearer #{token}" }

  def upload(io, filename, token: @token, **fields)
    file = Rack::Test::UploadedFile.new(io, 'application/octet-stream', original_filename: filename)
    post api_agent_job_outputs_path("j_#{@generation.id}"), params: { file:, node: '9', filename:, **fields },
                                                            headers: auth(token)
  end

  def upload_id = response.parsed_body['upload_id']

  def complete(*upload_ids)
    agent_message(@backend, { 'type' => 'job.completed', 'job_id' => "j_#{@generation.id}",
                              'outputs' => upload_ids.map { { 'upload_id' => it } } })
  end

  def glb = tempfile("glTF\x02\x00\x00\x00".b)

  def tempfile(bytes, name = 'upload')
    file = Tempfile.new(name)
    file.binmode
    file.write(bytes)
    file.rewind
    file
  end

  test 'a real PNG is accepted' do
    upload(file_fixture('pixel.png').open, 'ComfyUI_00001_.png')

    assert_response :success
    upload_id = response.parsed_body['upload_id']
    output = GenerationOutput.find_by!(upload_id:)

    assert_equal 'image/png', output.mime
    assert_equal @backend, output.backend
  end

  test 'the same upload twice returns the same id' do
    upload(file_fixture('pixel.png').open, 'a.png')
    first = response.parsed_body['upload_id']
    upload(file_fixture('pixel.png').open, 'a.png')

    assert_equal first, response.parsed_body['upload_id']
    assert_equal 1, GenerationOutput.where(upload_id: first).count
  end

  test 'HTML renamed to .png is refused' do
    upload(tempfile('<html><script>alert(1)</script></html>'), 'evil.png')

    assert_response :unsupported_media_type
  end

  test 'SVG and HTML are never accepted' do
    upload(tempfile('<svg xmlns="http://www.w3.org/2000/svg"></svg>'), 'image.svg')

    assert_response :unsupported_media_type
    upload(tempfile('<html></html>'), 'page.html')

    assert_response :unsupported_media_type
  end

  test 'a text 3D file with markup is refused, a real one accepted' do
    upload(tempfile('<script>x</script>'), 'mesh.obj')

    assert_response :unsupported_media_type
    upload(tempfile("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"), 'mesh.obj')

    assert_response :success
    upload(tempfile("glTF\x02\x00\x00\x00".b), 'mesh.glb')

    assert_response :success
  end

  test 'filenames are sanitized' do
    assert_equal 'evil.png', Agent::Outputs.sanitize_filename("../../etc/\u202Eevil.png")
    assert_equal 'hidden.png', Agent::Outputs.sanitize_filename('...hidden.png')
    assert_equal Agent::Outputs::MAX_FILENAME, Agent::Outputs.sanitize_filename("#{'a' * 300}.png").length
  end

  test 'files over the size limit are refused' do
    with_env('AGENT_MAX_OUTPUT_FILE_GB' => '0.00000001') do
      upload(file_fixture('pixel.png').open, 'big.png')
    end

    assert_response :content_too_large
  end

  test 'uploads from an earlier attempt do not count toward the job limit' do
    @generation.update!(dispatched_at: 1.minute.ago)
    @generation.generation_outputs.create!(upload_id: 'u_old', backend: @backend, node: '9', filename: 'old.png',
                                           kind: 'image', bytes: 10.gigabytes, created_at: 1.hour.ago)
    upload(file_fixture('pixel.png').open, 'retry.png')

    assert_response :success
  end

  test 'completing discards uploads from earlier attempts' do
    @generation.generation_outputs.create!(upload_id: 'u_old', backend: @backend, node: '9', filename: 'old.png',
                                           kind: 'image', bytes: 1)
    upload(file_fixture('pixel.png').open, 'a.png')
    upload_id = response.parsed_body['upload_id']
    agent_message(@backend, { 'type' => 'job.completed', 'job_id' => "j_#{@generation.id}",
                              'outputs' => [{ 'upload_id' => upload_id }] })

    assert_equal [upload_id], @generation.generation_outputs.pluck(:upload_id)
    assert_equal 1, @generation.reload.outputs.count
  end

  test 'a 3D preview is stored as a preview, apart from an output of the same name' do
    upload(file_fixture('pixel.png').open, 'mesh.png')
    output_id = upload_id
    upload(file_fixture('pixel.png').open, 'mesh.png', role: 'preview')

    assert_response :success
    assert_not_equal output_id, upload_id
    assert_equal 'preview', GenerationOutput.find_by!(upload_id:).kind
  end

  test 'a preview must be an image' do
    upload(glb, 'mesh_preview.glb', role: 'preview')

    assert_response :unsupported_media_type
    assert_includes response.parsed_body['error'], 'PNG, JPEG or WebP'
  end

  test 'oversized previews are refused' do
    with_env('AGENT_MAX_PREVIEW_MB' => '0.00001') do
      upload(file_fixture('pixel.png').open, 'mesh_preview.png', role: 'preview')
    end

    assert_response :content_too_large
  end

  test 'completing a 3D job keeps its preview as the poster of the first model' do
    @generation.update!(kind: :model_3d)
    upload(glb, 'mesh.glb')
    first = upload_id
    upload(file_fixture('pixel.png').open, 'mesh_preview.png', role: 'preview')
    preview = upload_id
    upload(glb, 'white.glb')
    complete(first, preview, upload_id)
    @generation.reload

    assert_predicate @generation, :succeeded?
    assert_equal %w[mesh.glb white.glb], @generation.outputs.map { it.filename.to_s }.sort
    assert_predicate @generation.output_poster, :attached?
    assert_equal 'image/png', @generation.output_poster.content_type
  end

  test 'a preview without a 3D output is dropped' do
    upload(file_fixture('pixel.png').open, 'a.png')
    output = upload_id
    upload(file_fixture('pixel.png').open, 'a_preview.png', role: 'preview')
    preview_key = GenerationOutput.find_by!(upload_id:).storage_key
    perform_enqueued_jobs { complete(output, upload_id) }

    assert_equal 1, @generation.reload.outputs.count
    assert_not @generation.output_poster.attached?
    assert_not ActiveStorage::Blob.exists?(key: preview_key)
  end

  test 'another server cannot upload to this job' do
    other = create_agent_backend!(owner: @alice, name: 'Other')
    upload(file_fixture('pixel.png').open, 'a.png', token: create_agent_key!(other))

    assert_response :not_found
  end

  test 'no key, no access' do
    post api_agent_job_outputs_path("j_#{@generation.id}")

    assert_response :unauthorized
  end

  test 'inputs stream with a length and only while the job is on the server' do
    blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture('pixel.png').open, filename: 'in.png',
                                                  content_type: 'image/png')
    GenerationInput.create!(generation: @generation, input_id: 'in_0', storage_key: blob.key, filename: 'in.png',
                            mime: 'image/png', bytes: blob.byte_size)

    get api_agent_job_input_path("j_#{@generation.id}", 'in_0'), headers: auth

    assert_response :success
    assert_equal blob.byte_size.to_s, response.headers['Content-Length']
    assert_equal file_fixture('pixel.png').binread, response.body.b

    @generation.update!(agent_state: 'completed')
    get api_agent_job_input_path("j_#{@generation.id}", 'in_0'), headers: auth

    assert_response :not_found
  end

  test 'shared outputs are served with nosniff and a sandbox' do
    generation = generations(:alice_done)
    generation.update!(status: :succeeded)
    generation.outputs.attach(io: file_fixture('pixel.png').open, filename: 'out.png', content_type: 'image/png')
    generation.create_public_link!

    get public_share_output_path(generation.public_token, 0)

    assert_response :success
    assert_equal 'nosniff', response.headers['X-Content-Type-Options']
    assert_match 'sandbox', response.headers['Content-Security-Policy']
  end

  test 'a key can be checked without connecting' do
    key = @backend.backend_keys.first
    key.update!(last_ip: '10.0.0.5', last_used_at: 1.day.ago)
    get '/api/agent/key', headers: auth

    assert_response :success
    assert_equal '10.0.0.5', key.reload.last_ip
    assert_operator key.last_used_at, :<, 1.hour.ago
    assert_equal @backend.name, response.parsed_body['server']
    assert_equal "#{@token[0, 12]}…", response.parsed_body['key']
  end

  test 'a refused key says why' do
    get '/api/agent/key', headers: auth('cmf_nope')

    assert_response :unauthorized
    assert_match(/doesn’t recognize/, response.parsed_body['error'])

    @backend.backend_keys.update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    get '/api/agent/key', headers: auth

    assert_match(/revoked/, response.parsed_body['error'])

    @backend.update!(deleted_at: Time.current)
    get '/api/agent/key', headers: auth

    assert_match(/was deleted/, response.parsed_body['error'])
  end
end

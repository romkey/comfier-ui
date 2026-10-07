require 'test_helper'

class GenerationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in_as users(:alice)
  end

  test 'creating a generation queues it and returns to the studio' do
    assert_difference('users(:alice).generations.count', 1) do
      assert_enqueued_with(job: SubmitGenerationJob) do
        post generations_path, params: { generation: { workflow_id: workflows(:sd_image).id, prompt: 'A fox',
                                                       aspect_ratio: '4:3' } }
      end
    end

    assert_redirected_to '/image'
    generation = users(:alice).generations.recent.first

    assert_predicate generation, :queued?
    assert_equal '4:3', generation.aspect_ratio
  end

  test 'creating with an uploaded image' do
    post generations_path, params: { generation: { workflow_id: workflows(:image_to_3d).id, input_image: png_upload } }

    assert_redirected_to '/3d'
    assert_predicate users(:alice).generations.recent.first.input_image, :attached?
  end

  test 'an invalid submission re-renders the form with the error and keeps the input' do
    assert_no_difference('Generation.count') do
      post generations_path, params: { generation: { workflow_id: workflows(:sd_image).id, prompt: '',
                                                     negative_prompt: 'keep me' } }
    end

    assert_response :unprocessable_content
    assert_select '.alert-danger', text: /Prompt can't be blank/
    assert_select 'textarea[name="generation[negative_prompt]"]', text: 'keep me'
    assert_no_enqueued_jobs(only: SubmitGenerationJob)
  end

  test 'a disabled workflow cannot be used' do
    post generations_path, params: { generation: { workflow_id: workflows(:retired_image).id, prompt: 'x' } }

    assert_response :unprocessable_content
  end

  test 'results lists only the user\'s own work' do
    get generations_path

    assert_response :success
    assert_select '.result-card', count: 3
    assert_select '.result-card', text: /Bob's secret project/, count: 0
  end

  test 'results marks shared work with an icon on the thumbnail' do
    generations(:alice_done).share!

    get generations_path

    assert_select '.result-shared .bi-share-fill', count: 1
  end

  test 'results can be filtered to shared work and to work with a public link' do
    generations(:alice_done).share!
    generations(:alice_failed).update!(public_token: 'tok')

    get generations_path, params: { shared: '1' }

    assert_select '.result-card', count: 1
    assert_select '.result-card', text: /A lighthouse at dusk/
    assert_select 'a.filter-chip.active', text: /Shared/

    get generations_path, params: { public: '1', kind: 'video' }

    assert_select '.result-card', count: 1
    assert_select '.result-card', text: /A dancing robot/
    assert_select '.text-12', text: /2 filters active/
  end

  test 'results has a select mode with a checkbox per card' do
    get generations_path

    assert_select 'button', text: 'Select'
    assert_select 'form#results_bulk_form'
    assert_select '.result-card input[type=checkbox][name="ids[]"][form=results_bulk_form]', count: 3
  end

  test 'bulk sharing and public links skip unfinished work' do
    done = generations(:alice_done)
    running = generations(:alice_running)

    post bulk_generations_path, params: { operation: 'share', ids: [done.id, running.id], shared: '1' }

    assert_redirected_to generations_path(shared: '1')
    assert_equal 'Shared 1 result with everyone.', flash[:notice]
    assert_predicate done.reload, :shared?
    assert_not_predicate running.reload, :shared?

    post bulk_generations_path, params: { operation: 'link', ids: [done.id, running.id] }

    assert_predicate done.reload, :publicly_linked?
    assert_not_predicate running.reload, :publicly_linked?

    post bulk_generations_path, params: { operation: 'unlink', ids: [done.id] }

    assert_not_predicate done.reload, :publicly_linked?

    post bulk_generations_path, params: { operation: 'unshare', ids: [done.id] }

    assert_not_predicate done.reload, :shared?
  end

  test 'bulk delete only touches the user\'s own results' do
    ids = [generations(:alice_done).id, generations(:alice_failed).id, generations(:bob_done).id]

    assert_difference('Generation.count', -2) do
      post bulk_generations_path, params: { operation: 'delete', ids: }
    end

    assert_equal 'Deleted 2 results.', flash[:notice]
    assert Generation.exists?(generations(:bob_done).id)
  end

  test 'a page past the end falls back to the last page and keeps the filters' do
    get generations_path, params: { kind: 'image', page: 5 }

    assert_redirected_to generations_path(kind: 'image')
  end

  test 'emptying the last page with a bulk action lands on the new last page' do
    base = generations(:alice_done).attributes.except('id', 'created_at', 'updated_at')
    Generation.insert_all(Array.new(GenerationsController::PER_PAGE - 2) { base }) # rubocop:disable Rails/SkipsModelValidations
    oldest = users(:alice).generations.recent.last

    post bulk_generations_path, params: { operation: 'delete', ids: [oldest.id], page: 2 }

    assert_redirected_to generations_path(page: 2)
    follow_redirect!

    assert_redirected_to generations_path
    follow_redirect!

    assert_select '.alert', text: /Deleted 1 result\./
  end

  test 'bulk with nothing selected or an unknown operation changes nothing' do
    post bulk_generations_path, params: { operation: 'delete' }

    assert_redirected_to generations_path
    assert_equal 'Select at least one result.', flash[:alert]

    assert_no_difference('Generation.count') do
      post bulk_generations_path, params: { operation: 'explode', ids: [generations(:alice_done).id] }
    end
  end

  test 'results can be filtered by kind and status' do
    get generations_path, params: { kind: 'video' }

    assert_select '.result-card', count: 1
    assert_select '.text-12', text: /1 filter active/

    get generations_path, params: { status: 'failed' }

    assert_select '.result-card', text: /A dancing robot/
    assert_select '.filter-chip.danger', text: /Failed/
  end

  test 'results ignores unknown filters' do
    get generations_path, params: { kind: 'hologram', status: 'exploded' }

    assert_select '.result-card', count: 3
  end

  test 'results paginates' do
    30.times { |i| users(:alice).generations.create!(workflow: workflows(:sd_image), prompt: "p#{i}") }

    get generations_path

    assert_select '.result-card', count: GenerationsController::PER_PAGE
    assert_select 'nav[aria-label=Pages]'
  end

  test 'shows a finished generation with its outputs' do
    generation = generations(:alice_done)
    generation.outputs.attach(io: file_fixture('pixel.png').open, filename: 'out.png', content_type: 'image/png')

    get generation_path(generation)

    assert_response :success
    assert_select 'h1', text: 'A lighthouse at dusk'
    assert_select 'img.output-media'
    assert_select 'a', text: /Download/
    assert_select 'button', text: /Run again/
    assert_select 'dd', text: '42'
    assert_select '.text-12', text: /Started processing/
    assert_select '.text-12', text: /Processing took/
  end

  test 'a 3D result shows its preview image on the first model only' do
    generation = generations(:alice_done)
    generation.update!(kind: :model_3d)
    %w[textured.glb white.glb].each do |name|
      generation.outputs.attach(io: StringIO.new('glTF'), filename: name, content_type: 'model/gltf-binary')
    end
    generation.output_poster.attach(io: file_fixture('pixel.png').open, filename: 'textured_preview.png',
                                    content_type: 'image/png')

    get generation_path(generation)

    assert_select '.output-model-preview img[alt="Preview of textured.glb"]', count: 1
    assert_select '.output-model-badge', count: 1
    assert_select '.output-file', text: /white\.glb/, count: 1

    get generations_path

    assert_select '.result-card .output-model-preview img', count: 1
  end

  test 'a 3D result without a preview shows the file' do
    generation = generations(:alice_done)
    generation.outputs.attach(io: StringIO.new('glTF'), filename: 'mesh.glb', content_type: 'model/gltf-binary')

    get generation_path(generation)

    assert_select '.output-model-preview', count: 0
    assert_select '.output-file', text: /mesh\.glb/
  end

  test 'shows why a generation failed' do
    get generation_path(generations(:alice_failed))

    assert_select '.status-panel', text: /Value not in list/
  end

  test 'hides backend internals from non-admins' do
    get generation_path(generations(:alice_done))

    assert_select 'code', text: 'done-prompt', count: 0
  end

  test 'cannot see someone else\'s generation' do
    get generation_path(generations(:bob_done))

    assert_response :not_found
  end

  test 'run again queues a copy with the same settings' do
    original = generations(:alice_done)

    assert_enqueued_with(job: SubmitGenerationJob) { post retry_generation_path(original) }
    copy = users(:alice).generations.recent.first

    assert_redirected_to generation_path(copy)
    assert_equal original.prompt, copy.prompt
    assert_equal original.negative_prompt, copy.negative_prompt
    assert_not_equal original.id, copy.id
  end

  test 'run again reuses the input image' do
    original = users(:alice).generations.create!(workflow: workflows(:image_to_3d), input_image: png_upload)

    post retry_generation_path(original)

    assert_equal original.input_image.blob, users(:alice).generations.recent.first.input_image.blob
  end

  test 'creating from a tweak reuses the reference without re-uploading' do
    source = users(:alice).generations.create!(workflow: workflows(:image_to_3d), input_image: png_upload)
    source.outputs.attach(io: StringIO.new(png_bytes), filename: 'out.png', content_type: 'image/png')
    source.succeed!

    assert_enqueued_with(job: SubmitGenerationJob) do
      post generations_path, params: {
        generation: {
          workflow_id: workflows(:image_to_3d).id,
          reference_from_id: source.id,
          reference_source: 'result'
        }
      }
    end

    copy = users(:alice).generations.recent.first

    assert_equal source.outputs.first.blob, copy.input_image.blob
  end

  test 'deleting a generation' do
    assert_difference('Generation.count', -1) { delete generation_path(generations(:alice_done)) }
    assert_redirected_to generations_path
  end

  test 'cannot delete someone else\'s generation' do
    assert_no_difference('Generation.count') { delete generation_path(generations(:bob_done)) }
    assert_response :not_found
  end

  test 'cancelled results show as cancelled, not failed' do
    generation = generations(:alice_running)
    backend = backends(:gpu)
    stub_request(:post, comfy_url(backend, 'queue')).with(body: { delete: ['running-prompt'] }.to_json)
    stub_request(:post, comfy_url(backend, 'interrupt')).with(body: { prompt_id: 'running-prompt' }.to_json)

    post cancel_generation_path(generation)

    get generation_path(generation)

    assert_response :success
    assert_select '.badge', text: 'Cancelled'
    assert_select '.badge', text: 'Failed', count: 0
    assert_select '.status-panel', text: /You cancelled this job/
    assert_select '.status-panel', text: /This didn't work/, count: 0
  end

  test 'cancelling a running generation' do
    generation = generations(:alice_running)
    backend = backends(:gpu)
    stub_request(:post, comfy_url(backend, 'queue')).with(body: { delete: ['running-prompt'] }.to_json)
    stub_request(:post, comfy_url(backend, 'interrupt')).with(body: { prompt_id: 'running-prompt' }.to_json)

    post cancel_generation_path(generation)

    assert_redirected_to queue_path
    assert_equal 'Cancelled.', flash[:notice]
    assert_predicate generation.reload, :failed?
    assert_equal 'Cancelled', generation.error_message
  end

  test 'cannot cancel someone else\'s generation' do
    sign_in_as users(:bob)

    post cancel_generation_path(generations(:alice_running))

    assert_response :not_found
    assert_predicate generations(:alice_running).reload, :running?
  end

  test 'admins can cancel anyone\'s generation' do
    sign_in_as users(:admin)
    generation = generations(:alice_running)
    backend = backends(:gpu)
    stub_request(:post, comfy_url(backend, 'queue')).with(body: { delete: ['running-prompt'] }.to_json)
    stub_request(:post, comfy_url(backend, 'interrupt')).with(body: { prompt_id: 'running-prompt' }.to_json)

    post cancel_generation_path(generation)

    assert_redirected_to queue_path
    assert_predicate generation.reload, :failed?
  end

  test 'the result page shows a cancel button while a job is running' do
    get generation_path(generations(:alice_running))

    assert_select 'button', text: /Cancel/
  end
end

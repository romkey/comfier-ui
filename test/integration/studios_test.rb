require 'test_helper'

class StudiosTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:alice)
  end

  test 'the image page shows only fields the default workflow uses' do
    get '/image'

    assert_response :success
    assert_select 'h1', text: /Image/
    assert_select 'textarea[name="generation[prompt]"]'
    assert_select 'input[name="generation[aspect_ratio]"]', count: Generation::ASPECT_RATIOS.size
    assert_select 'textarea[name="generation[negative_prompt]"]'
    assert_select 'input[name="generation[seed]"]'
    assert_select "input[name='generation[workflow_id]'][value='#{workflows(:sd_image).id}']"
  end

  test 'the image page hides fields the default workflow does not use' do
    get '/image'

    assert_select 'input[name="generation[duration]"]', count: 0
    assert_select 'input[name="generation[input_image]"]', count: 0
  end

  test 'lets the user pick between styles, excluding disabled ones' do
    get '/image'

    assert_select '.filter-chip', text: 'SD 1.5'
    assert_select '.filter-chip', text: 'SDXL'
    assert_select '.filter-chip', text: 'Retired', count: 0
  end

  test 'choosing a style switches the form' do
    get '/image', params: { workflow_id: workflows(:sdxl_image).id }

    assert_select "input[name='generation[workflow_id]'][value='#{workflows(:sdxl_image).id}']"
    assert_select 'textarea[name="generation[negative_prompt]"]', count: 0
  end

  test 'switching styles carries the settings over' do
    carry = { prompt: 'a red fox', aspect_ratio: '16:9', negative_prompt: 'blurry', seed: '42' }
    get '/image', params: { workflow_id: workflows(:sd_image).id, carry: }

    assert_select 'textarea[name="generation[prompt]"]', text: 'a red fox'
    assert_select 'input[name="generation[aspect_ratio]"][value="16:9"][checked]'
    assert_select 'textarea[name="generation[negative_prompt]"]', text: 'blurry'
    assert_select 'input[name="generation[seed]"][value="42"]'
    assert_select '.studio-needs-input', count: 0
  end

  test 'switching to a style that needs more points out what is missing' do
    img2img = engine_workflow!(name: 'FLUX img2img', preset: 'flux1-dev-img2img')
    get '/image', params: { workflow_id: img2img.id, carry: { prompt: '', denoise: '40' } }

    assert_select '.studio-needs-input input[type=file][name="generation[input_image]"]'
    assert_select '.studio-needs-input textarea[name="generation[prompt]"]'
    assert_select '[data-style-switch-target="note"]', text: /highlighted fields/
    assert_select 'input[name="generation[denoise]"][value="40"]'
  end

  test 'a fresh page highlights nothing' do
    get '/image'

    assert_select '.studio-needs-input', count: 0
    assert_select '[data-style-switch-target="note"]', count: 0
  end

  test 'style chips switch in place and keep the result being tweaked' do
    source = generations(:alice_done)
    get '/image', params: { from: source.id }

    assert_select ".filter-chip[data-action='style-switch#switch'][href*='from=#{source.id}']", minimum: 1
    assert_select 'form.studio-form[data-controller="style-switch"]'
  end

  test 'a server picked for the previous style is dropped if it cannot run this one' do
    legacy = Backend.create!(name: 'Old box', connection_kind: 'legacy', base_url: 'http://comfy.test:8188',
                             enabled: true)
    mflux = engine_workflow!
    get '/image', params: { workflow_id: mflux.id, carry: { prompt: 'x', pinned_backend_id: legacy.id } }

    assert_select 'select[name="generation[pinned_backend_id]"] option[selected][value]', count: 0
  end

  test 'the video page asks for a length' do
    get '/video'

    assert_select 'input[name="generation[duration]"][value="5"]'
  end

  test 'the 3D page asks for a picture' do
    get '/3d'

    assert_select 'input[type=file][name="generation[input_image]"]'
    assert_select 'textarea[name="generation[prompt]"]', count: 0
  end

  test 'a page with no workflow is calm for users' do
    get '/audio'

    assert_response :success
    assert_select '.status-panel', text: /Audio generation isn't set up yet/
    assert_select 'form.studio-form', count: 0
    assert_select 'a', text: /Add audio workflow/, count: 0
  end

  test 'admins are offered a way to set up an empty page' do
    sign_in_as users(:admin)
    get '/audio'

    assert_select "a[href='#{new_admin_workflow_path(kind: 'audio')}']", text: /Add audio workflow/
  end

  test 'shows the user their own recent work for this kind only' do
    get '/image'

    assert_select "##{ActionView::RecordIdentifier.dom_id(generations(:alice_done))}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(generations(:alice_failed))}", count: 0
    assert_select "##{ActionView::RecordIdentifier.dom_id(generations(:bob_done))}", count: 0
  end

  test 'prefills from an earlier generation' do
    get '/image', params: { from: generations(:alice_done).id }

    assert_select 'textarea[name="generation[prompt]"]', text: 'A lighthouse at dusk'
    assert_select 'textarea[name="generation[negative_prompt]"]', text: 'blurry'
  end

  test 'prefills a reused reference and offers original vs result when tweaking' do
    source = users(:alice).generations.create!(workflow: workflows(:image_to_3d), input_image: png_upload)
    source.outputs.attach(io: StringIO.new(png_bytes), filename: 'out.png', content_type: 'image/png')
    source.succeed!

    get '/3d', params: { from: source.id }

    assert_select 'img[alt="Reference"]'
    assert_select 'input[name="generation[reference_from_id]"][value=?]', source.id.to_s
    assert_select 'input[name="generation[reference_source]"][value="result"]'
    assert_select 'a.filter-chip.active', text: 'Last result'
    assert_select 'a.filter-chip', text: 'Original upload'

    get '/3d', params: { from: source.id, reference: 'original' }

    assert_select 'input[name="generation[reference_source]"][value="original"]'
    assert_select 'a.filter-chip.active', text: 'Original upload'
  end

  test 'cannot prefill from someone else\'s generation' do
    get '/image', params: { from: generations(:bob_done).id }

    assert_select 'textarea[name="generation[prompt]"]', text: ''
  end

  test 'uses the user defaults for a fresh form' do
    users(:alice).update!(default_negative_prompt: 'watermark', default_aspect_ratio: '9:16')
    get '/image'

    assert_select 'textarea[name="generation[negative_prompt]"]', text: 'watermark'
    assert_select 'input[name="generation[aspect_ratio]"][value="9:16"][checked]'
  end

  test 'warns when no backend is available' do
    backends(:gpu).update!(enabled: false)
    get '/image'

    assert_select '.status-panel.status-attention', text: /No ComfyUI backend is available/
  end

  test 'grays out servers that do not have the workflow models installed' do
    ready = create_agent_backend!(owner: users(:alice), name: 'Studio ready', visibility: 'public')
    bring_online_for!(ready, workflows(:sd_image))
    Agent::Availability.recompute_for_backend!(ready)

    missing = create_agent_backend!(owner: users(:alice), name: 'Studio empty', visibility: 'public')
    bring_online!(missing, node_types: inventory_for(workflows(:sd_image))[:node_types])
    Agent::Availability.recompute_for_backend!(missing)

    get '/image'

    assert_select 'select[name="generation[pinned_backend_id]"] option[disabled]',
                  text: /Studio empty.*models not installed yet/
    assert_select 'select[name="generation[pinned_backend_id]"] option:not([disabled])', text: /Studio ready/
  end
end

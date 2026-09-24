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
end

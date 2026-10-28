require 'test_helper'

# A server owner's model overrides page, and where overrides show up elsewhere.
class ModelOverridesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  CHECKPOINT = 'v1-5-pruned-emaonly-fp16.safetensors'.freeze
  REPLACEMENT = 'v1-5-pruned-emaonly-q8.safetensors'.freeze
  LINK = "https://huggingface.co/x/#{REPLACEMENT}".freeze
  USES_INSTEAD = /#{Regexp.escape("Uses checkpoints/#{REPLACEMENT} in place of checkpoints/#{CHECKPOINT}")}/

  setup do
    @alice = users(:alice)
    @workflow = workflows(:sd_image)
    @backend = create_agent_backend!(owner: @alice)
    @socket = bring_online_for!(@backend, @workflow)
    sign_in_as @alice
  end

  def override!(**attrs)
    @backend.model_overrides.create!({ folder: 'checkpoints', filename: CHECKPOINT, replacement_filename: REPLACEMENT,
                                       url: LINK, bytes: 2.gigabytes, sha256: 'c' * 64 }.merge(attrs))
  end

  def save(*rows)
    overrides = rows.each_with_index.to_h { |row, index| [index.to_s, row] }
    patch server_model_overrides_path(@backend), params: { overrides: }
  end

  test "the page lists the server's workflow files, each with an Override link" do
    get server_model_overrides_path(@backend)

    assert_response :success
    assert_select 'h1', 'Model overrides'
    assert_select "#file-checkpoints-#{CHECKPOINT.parameterize}" do
      assert_select 'td', text: /SD 1.5/
      assert_select 'a[href*=?]', 'file=checkpoints', text: 'Override'
    end
  end

  test 'an Override link fills in the new row' do
    get server_model_overrides_path(@backend, file: "checkpoints/#{CHECKPOINT}", workflow_id: @workflow.id)

    assert_select '#new-override' do
      assert_select 'option[selected]', text: "checkpoints/#{CHECKPOINT}"
      assert_select 'option[selected]', text: 'SD 1.5'
    end
  end

  test 'adding an override saves it, logs it, and the server then needs the replacement' do
    save({ file: "checkpoints/#{CHECKPOINT}", workflow_id: '', replacement_filename: REPLACEMENT, url: LINK })

    assert_redirected_to server_model_overrides_path(@backend)
    override = @backend.model_overrides.sole

    assert_equal [CHECKPOINT, REPLACEMENT, LINK], override.values_at(:filename, :replacement_filename, :url)
    assert_equal @alice, override.created_by
    assert_match "added checkpoints/#{CHECKPOINT}", flash[:notice]
    assert ActivityLog.exists?(kind: 'server_updated', subject: @backend, user: @alice)
    assert_equal [REPLACEMENT], Agent::Availability.compute(@workflow, @backend.reload).models.pluck('filename')
  end

  test 'a new link forgets the old size and checksum and looks them up again' do
    override = override!

    assert_enqueued_with(job: EnrichModelOverrideJob) do
      save({ id: override.id, replacement_filename: REPLACEMENT, url: 'https://huggingface.co/x/other.safetensors' })
    end

    assert_equal [nil, nil], override.reload.values_at(:bytes, :sha256)
  end

  test 'one bad row saves nothing and keeps what was typed' do
    keep = override!
    gone = override!(workflow: @workflow, replacement_filename: 'for-sd15.safetensors')

    save({ id: gone.id, remove: '1' }, { id: keep.id, replacement_filename: REPLACEMENT, url: 'ftp://nope' })

    assert_response :unprocessable_content
    assert_select '.alert-danger', text: /single http\(s\) URL/
    assert_select "input[value='ftp://nope']"
    assert_select "##{ActionView::RecordIdentifier.dom_id(gone)} input[type=checkbox][checked]"
    assert_equal 2, @backend.model_overrides.count
    assert_equal LINK, keep.reload.url
  end

  test 'removing an override puts the original file back' do
    override = override!

    save({ id: override.id, remove: '1' })

    assert_empty @backend.model_overrides.reload
    assert_predicate Agent::Availability.compute(@workflow, @backend.reload), :ready?
  end

  test "other people can't see or change a server's overrides" do
    override!
    sign_in_as users(:bob)

    get server_model_overrides_path(@backend)

    assert_response :not_found
    save({ id: @backend.model_overrides.sole.id, remove: '1' })

    assert_response :not_found
    assert_equal 1, @backend.model_overrides.count
  end

  test "the server's workflows link to the page, and say which use overridden files" do
    override!

    get server_styles_path(@backend)

    assert_select 'a[href=?]', server_model_overrides_path(@backend), text: 'Model overrides'
    assert_select "##{ActionView::RecordIdentifier.dom_id(@workflow, :server_style)} a", text: 'Uses 1 overridden file'
  end

  test "a workflow's requirements page says what each server uses instead" do
    override!
    sign_in_as users(:admin)

    get requirements_admin_workflow_path(@workflow)

    assert_select 'td', text: USES_INSTEAD
  end
end

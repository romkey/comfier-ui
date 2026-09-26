require 'test_helper'

class ReportsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @generation = generations(:alice_done)
    @generation.update!(shared_at: Time.current, status: :succeeded)
    @generation.outputs.attach(io: file_fixture('pixel.png').open, filename: 'out.png', content_type: 'image/png')
    @generation.create_public_link!
    Report.where(generation_id: @generation.id).delete_all
    ReportCase.where(generation_id: @generation.id).delete_all
  end

  test 'members can report someone else shared result' do
    sign_in_as users(:bob)

    assert_enqueued_with(job: NotifyAdminsOfReportJob) do
      post shared_report_path(@generation), params: report_params
    end

    assert_redirected_to shared_path(@generation)
    assert_equal 1, ReportCase.open_cases.where(generation_id: @generation.id).count
  end

  test 'owners do not see the report button on their own shared result' do
    sign_in_as users(:alice)
    get shared_path(@generation)

    assert_response :success
    assert_select 'button[aria-label="Report this result"]', count: 0
  end

  test 'anonymous visitors can report via public link' do
    assert_enqueued_with(job: NotifyAdminsOfReportJob) do
      post public_share_report_path(@generation.public_token), params: report_params
    end

    assert_redirected_to public_share_path(@generation.public_token)
  end

  test 'honeypot submissions are accepted silently without notifying' do
    assert_no_enqueued_jobs(only: NotifyAdminsOfReportJob) do
      assert_no_difference -> { Report.where(generation_id: @generation.id).count } do
        post public_share_report_path(@generation.public_token),
             params: report_params.merge(ReportSubmission::HONEYPOT_PARAM => 'spam')
      end
    end
  end

  test 'hidden results are not reachable by public link' do
    @generation.update!(hidden_for_review_at: Time.current)

    get public_share_path(@generation.public_token)

    assert_response :not_found
  end

  test 'invalid reports require category and reason' do
    sign_in_as users(:bob)

    post shared_report_path(@generation), params: { report: { category: '', reason: '' } }

    assert_redirected_to shared_path(@generation)
    assert_equal 0, Report.where(generation_id: @generation.id).count
  end

  private

  def report_params
    { report: { category: 'code_of_conduct', reason: 'Breaks our rules', contact_email: 'reporter@example.com' } }
  end
end

require 'test_helper'

module Admin
  class ReportsTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      @generation = generations(:alice_done)
      @generation.update!(shared_at: Time.current, status: :succeeded)
      @generation.create_public_link!
      @case = ReportCase.record!(
        @generation,
        category: 'harassment',
        reason: 'Bad content',
        source: :member,
        reporter_digest: 'abc',
        reporter_id: users(:bob).id
      )[:report].report_case
    end

    test 'non-admins cannot access reports' do
      sign_in_as users(:alice)

      get admin_reports_path

      assert_response :not_found
    end

    test 'admin can view report case with generation actions' do
      sign_in_as users(:admin)

      get admin_report_path(@case)

      assert_response :success
      assert_match 'Delete result', response.body
    end

    test 'admin review removed unshares and revokes public link' do
      sign_in_as users(:admin)

      assert_enqueued_with(job: NotifyOwnerOfModerationJob) do
        patch admin_report_path(@case), params: {
          report_case: { conclusion: 'removed', review_note: 'Confirmed' }
        }
      end

      @generation.reload
      @case.reload

      assert_predicate @case, :reviewed?
      assert_predicate @case, :removed?
      assert_not @generation.shared?
      assert_not @generation.publicly_linked?
    end

    test 'admin review okay clears hidden state' do
      @generation.update!(hidden_for_review_at: Time.current)
      sign_in_as users(:admin)

      patch admin_report_path(@case), params: { report_case: { conclusion: 'okay' } }

      assert_not @generation.reload.hidden_for_review?
    end

    test 'revoke all style actions notify the owner' do
      sign_in_as users(:admin)

      assert_enqueued_with(job: NotifyOwnerOfModerationJob) do
        delete unshare_admin_report_path(@case)
      end
    end
  end
end

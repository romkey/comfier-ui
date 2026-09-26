require 'test_helper'

class ReportCaseTest < ActiveSupport::TestCase
  setup do
    @generation = generations(:bob_done)
    @generation.update!(shared_at: Time.current, status: :succeeded, hidden_for_review_at: nil)
    ReportCase.where(generation_id: @generation.id).delete_all
    AppSetting.current.update!(report_auto_hide_threshold: 3)
  end

  test 'groups reports into one open case' do
    ReportCase.record!(@generation, report_attrs(digest: 'a'))
    ReportCase.record!(@generation, report_attrs(digest: 'b'))

    assert_equal 1, ReportCase.open_cases.where(generation_id: @generation.id).count
    assert_equal 2, ReportCase.open_cases.find_by(generation_id: @generation.id).reports_count
  end

  test 'ignores repeat reporters on the same case' do
    ReportCase.record!(@generation, report_attrs(digest: 'same'))
    result = ReportCase.record!(@generation, report_attrs(digest: 'same'))

    assert_not result[:created]
    assert_equal 1, ReportCase.open_cases.find_by(generation_id: @generation.id).reports_count
  end

  test 'auto-hides after distinct reporters reach threshold' do
    AppSetting.current.update!(report_auto_hide_threshold: 2)
    ReportCase.record!(@generation, report_attrs(digest: 'one'))
    result = ReportCase.record!(@generation, report_attrs(digest: 'two'))

    assert result[:auto_hidden]
    assert_predicate @generation.reload, :hidden_for_review?
  end

  test 'threshold of zero never auto-hides' do
    AppSetting.current.update!(report_auto_hide_threshold: 0)
    3.times { |n| ReportCase.record!(@generation, report_attrs(digest: n.to_s)) }

    assert_not @generation.reload.hidden_for_review?
  end

  test 'shared scope excludes hidden results' do
    @generation.update!(shared_at: Time.current, hidden_for_review_at: Time.current)

    assert_not_includes Generation.shared, @generation
  end

  private

  def report_attrs(digest:)
    {
      category: 'code_of_conduct',
      reason: 'Not okay',
      source: 'member',
      reporter_digest: digest
    }
  end
end

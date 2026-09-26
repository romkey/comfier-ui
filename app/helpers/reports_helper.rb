module ReportsHelper
  def report_case_status(case_record)
    if case_record.open?
      tag.span(class: 'badge text-bg-warning-subtle text-11') { 'Open' }
    else
      label = case_record.removed? ? 'Removed' : 'Okay'
      tag.span(class: 'badge text-bg-secondary-subtle text-11') { label }
    end
  end
end

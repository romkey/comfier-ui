require 'test_helper'

class ApplicationHelperTest < ActionView::TestCase
  setup { travel_to Time.zone.local(2026, 9, 23, 15, 0) }

  test 'friendly_time shows the time for today' do
    assert_dom_equal '<time datetime="2026-09-23T09:05:00Z" title="Sep 23, 2026 9:05:00 AM UTC">9:05 AM</time>',
                     friendly_time(Time.zone.local(2026, 9, 23, 9, 5))
  end

  test 'friendly_time uses relative days within a week' do
    assert_includes friendly_time(1.day.ago), '>Yesterday<'
    assert_includes friendly_time(3.days.ago), '>3 days ago<'
  end

  test 'friendly_time drops the year only for this year' do
    assert_includes friendly_time(Time.zone.local(2026, 4, 27)), '>Apr 27<'
    assert_includes friendly_time(Time.zone.local(2025, 4, 27)), '>Apr 27, 2025<'
  end

  test 'friendly_time is empty for nil' do
    assert_nil friendly_time(nil)
  end
end

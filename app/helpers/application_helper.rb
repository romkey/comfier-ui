module ApplicationHelper
  FLASH_CLASSES = { 'notice' => 'success', 'alert' => 'danger', 'warning' => 'warning' }.freeze

  def bootstrap_class_for(flash_type) = "alert-#{FLASH_CLASSES.fetch(flash_type.to_s, 'secondary')}"

  # Relative date with the full timestamp on hover.
  def friendly_time(time)
    return if time.nil?

    time = time.in_time_zone
    today = Time.zone.today
    label =
      if time.to_date == today then time.strftime('%-l:%M %p')
      elsif time.to_date == today - 1 then 'Yesterday'
      elsif time.to_date > today - 7 then "#{(today - time.to_date).to_i} days ago"
      elsif time.year == today.year then time.strftime('%b %-d')
      else time.strftime('%b %-d, %Y')
      end
    tag.time(label, datetime: time.iso8601, title: time.strftime('%b %-d, %Y %-l:%M:%S %p %Z'))
  end

  def nav_item(label, path, icon:, active: current_page?(path))
    tag.li(class: 'nav-item') do
      link_to path, class: ['nav-link', { active: }], aria: { current: active ? 'page' : nil } do
        safe_join([tag.i(class: "bi #{icon} me-1", aria: { hidden: true }), label])
      end
    end
  end

  def settings_nav_item(label, path, icon:, count: nil, attention: false)
    classes = ['settings-nav-item', { active: current_page?(path) || request.path.start_with?("#{path}/"), attention: }]
    link_to path, class: classes do
      safe_join([
        tag.i(class: "bi #{icon}", aria: { hidden: true }),
        tag.span(label, class: 'flex-grow-1'),
        (tag.span(count, class: 'num text-12') unless count.nil?)
      ].compact)
    end
  end
end

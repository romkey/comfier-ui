module Admin
  module UsersHelper
    def users_sort_link(label, column, default: 'desc')
      active = @sort == column
      dir = active && @sort_dir == 'asc' ? 'desc' : (active ? 'asc' : default)
      classes = ['table-sort-link', { active: }]

      link_to admin_users_path(sort: column, dir: dir), class: classes do
        safe_join([
          label,
          (tag.i(class: "bi bi-caret-#{@sort_dir == 'asc' ? 'up' : 'down'}-fill ms-1", aria: { hidden: true }) if active)
        ].compact)
      end
    end
  end
end

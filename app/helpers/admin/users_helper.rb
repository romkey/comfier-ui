module Admin
  module UsersHelper
    def users_sort_link(label, column, sort:, sort_dir:, default: 'desc')
      active = sort == column
      dir = if active
              sort_dir == 'asc' ? 'desc' : 'asc'
            else
              default
            end
      classes = ['table-sort-link', { active: }]

      link_to admin_users_path(sort: column, dir: dir), class: classes do
        parts = [label]
        if active
          caret = sort_dir == 'asc' ? 'up' : 'down'
          parts << tag.i(class: "bi bi-caret-#{caret}-fill ms-1", aria: { hidden: true })
        end
        safe_join(parts)
      end
    end
  end
end

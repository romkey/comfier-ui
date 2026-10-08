module Admin
  module TableSortHelper
    # A column heading that sorts the current page by `column`, flipping direction when it's already active.
    # `default:` is the direction a column starts in; other params (filters, say) are kept in the link.
    def table_sort_link(label, column, sort:, sort_dir:, **params)
      default = params.delete(:default) || 'desc'
      active = sort == column
      dir = if active
              sort_dir == 'asc' ? 'desc' : 'asc'
            else
              default
            end
      classes = ['table-sort-link', { active: }]

      link_to url_for(params.merge(sort: column, dir: dir)), class: classes do
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

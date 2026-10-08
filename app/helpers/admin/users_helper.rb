module Admin
  module UsersHelper
    def users_sort_link(label, column, sort:, sort_dir:, default: 'desc')
      table_sort_link(label, column, sort:, sort_dir:, default:)
    end
  end
end

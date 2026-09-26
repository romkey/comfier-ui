module Admin
  class UsersController < BaseController
    PER_PAGE = 50
    SORTS = %w[user last_login joined role generations].freeze

    def index
      @sort = params[:sort].presence_in(SORTS) || 'last_login'
      @sort_dir = params[:dir].presence_in(%w[asc desc]) || default_sort_dir(@sort)
      @pagy, @users = pagy(:offset, sorted_users, limit: PER_PAGE)
      @admin_count = User.where(admin: true).count
      @generation_counts = Generation.where(user_id: @users.map(&:id)).group(:user_id).count
    end

    private

    def default_sort_dir(sort)
      sort == 'user' ? 'asc' : 'desc'
    end

    def sorted_users
      dir = @sort_dir.upcase
      case @sort
      when 'user'
        User.order(Arel.sql(<<~SQL.squish))
          LOWER(COALESCE(NULLIF(users.name, ''), NULLIF(users.username, ''), NULLIF(users.email, ''), '')) #{dir},
          users.created_at DESC
        SQL
      when 'last_login'
        nulls = @sort_dir == 'asc' ? 'NULLS FIRST' : 'NULLS LAST'
        User.order(Arel.sql("users.last_signed_in_at #{dir} #{nulls}, users.created_at DESC"))
      when 'joined'
        User.order(created_at: @sort_dir, id: :asc)
      when 'role'
        User.order(admin: @sort_dir, created_at: :desc)
      when 'generations'
        User.left_joins(:generations).group('users.id')
            .order(Arel.sql("COUNT(generations.id) #{dir}, users.created_at DESC"))
      else
        User.order(Arel.sql('users.last_signed_in_at DESC NULLS LAST, users.created_at DESC'))
      end
    end
  end
end

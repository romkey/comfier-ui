module Admin
  class UsersController < BaseController
    PER_PAGE = 50
    SORTS = %w[user last_login joined role generations].freeze
    USER_NAME_ORDER = Arel.sql(
      "LOWER(COALESCE(NULLIF(users.name, ''), NULLIF(users.username, ''), NULLIF(users.email, ''), ''))"
    ).freeze
    GENERATION_COUNT = Arel.sql('COUNT(generations.id)').freeze

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
      {
        'user' => -> { order_by_expression(USER_NAME_ORDER).order(created_at: :desc) },
        'last_login' => -> { order_by_last_login },
        'joined' => -> { User.order(created_at: @sort_dir, id: :asc) },
        'role' => -> { User.order(admin: @sort_dir, created_at: :desc) },
        'generations' => -> { order_by_generation_count }
      }.fetch(@sort, -> { order_by_last_login_desc }).call
    end

    def order_by_last_login
      if @sort_dir == 'asc'
        User.order(Arel.sql('users.last_signed_in_at ASC NULLS FIRST, users.created_at DESC'))
      else
        order_by_last_login_desc
      end
    end

    def order_by_last_login_desc
      User.order(Arel.sql('users.last_signed_in_at DESC NULLS LAST, users.created_at DESC'))
    end

    def order_by_generation_count
      scope = User.left_joins(:generations).group('users.id')
      scope = @sort_dir == 'asc' ? scope.order(GENERATION_COUNT.asc) : scope.order(GENERATION_COUNT.desc)
      scope.order(created_at: :desc)
    end

    def order_by_expression(expression)
      @sort_dir == 'asc' ? User.order(expression.asc) : User.order(expression.desc)
    end
  end
end

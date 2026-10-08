module Admin
  class PublicLinksController < BaseController
    PER_PAGE = 50
    SORTS = %w[result owner kind shared views last_viewed].freeze
    TEXT_SORTS = %w[result owner kind].freeze
    RESULT_ORDER = Arel.sql("LOWER(COALESCE(NULLIF(generations.prompt, ''), ''))").freeze

    def index
      @kind = params[:kind].presence_in(GenerationKind.keys)
      @sort = params[:sort].presence_in(SORTS) || 'shared'
      @sort_dir = params[:dir].presence_in(%w[asc desc]) || (TEXT_SORTS.include?(@sort) ? 'asc' : 'desc')
      @kind_counts = Generation.publicly_linked.group(:kind).count
      scope = Generation.publicly_linked.includes(:user)
      scope = scope.where(kind: @kind) if @kind
      @pagy, @generations = pagy(:offset, sorted(scope), limit: PER_PAGE)
    end

    private

    # Ties fall back to the newest link, so paging is stable.
    def sorted(scope)
      {
        'result' => -> { scope.order(directed(RESULT_ORDER)) },
        'owner' => -> { scope.joins(:user).order(directed(UsersController::USER_NAME_ORDER)) },
        'kind' => -> { scope.order(kind: @sort_dir) },
        'views' => -> { scope.order(public_view_count: @sort_dir) },
        'last_viewed' => -> { scope.order(directed(Arel.sql('generations.public_last_viewed_at'), nulls: true)) },
        'shared' => -> { scope.order(public_shared_at: @sort_dir) }
      }.fetch(@sort).call.order(public_shared_at: :desc, id: :desc)
    end

    # Never-viewed links sort as the oldest views.
    def directed(expression, nulls: false)
      order = @sort_dir == 'asc' ? expression.asc : expression.desc
      return order unless nulls

      @sort_dir == 'asc' ? order.nulls_first : order.nulls_last
    end
  end
end

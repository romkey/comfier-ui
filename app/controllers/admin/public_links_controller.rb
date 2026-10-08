module Admin
  class PublicLinksController < BaseController
    PER_PAGE = 50

    def index
      scope = Generation.publicly_linked.includes(:user).with_attached_outputs.order(public_shared_at: :desc)
      @pagy, @generations = pagy(:offset, scope, limit: PER_PAGE)
    end
  end
end

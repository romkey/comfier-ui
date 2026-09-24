module Admin
  class BackendsController < BaseController
    before_action :set_backend, only: %i[edit update destroy check]

    def index
      @backends = Backend.ordered
    end

    def new
      @backend = Backend.new
    end

    def edit; end

    def create
      @backend = Backend.new(backend_params)
      if @backend.save
        @backend.check!
        redirect_to admin_backends_path, notice: connection_notice, status: :see_other
      else
        render :new, status: :unprocessable_content
      end
    end

    def update
      if @backend.update(backend_params)
        redirect_to admin_backends_path, notice: "Saved #{@backend.name}.", status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end

    def destroy
      @backend.destroy!
      redirect_to admin_backends_path, notice: "Removed #{@backend.name}.", status: :see_other
    end

    def check
      @backend.check!
      redirect_to admin_backends_path, notice: connection_notice, status: :see_other
    end

    private

    def set_backend
      @backend = Backend.find(params[:id])
    end

    def connection_notice
      status = @backend.last_check_ok ? 'is reachable' : 'could not be reached'
      "#{@backend.name} #{status}: #{@backend.last_check_message}"
    end

    # A blank token on edit means "keep the current one"; tick the clear box to remove it.
    def backend_params
      permitted = params.expect(backend: %i[name base_url auth_token enabled clear_auth_token])
      clear = ActiveModel::Type::Boolean.new.cast(permitted.delete(:clear_auth_token))
      permitted.delete(:auth_token) if permitted[:auth_token].blank?
      permitted[:auth_token] = nil if clear
      permitted
    end
  end
end

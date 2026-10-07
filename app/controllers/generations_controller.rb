# "Results": everything the user has generated, plus creating and re-running generations.
class GenerationsController < ApplicationController # rubocop:disable Metrics/ClassLength
  include StudioPage
  include GenerationReferenceReuse

  PER_PAGE = 24
  # Which of the selected results each bulk action applies to, and what it does to each. Sharing and links only
  # make sense for finished work, so those skip anything still running or failed.
  BULK_OPERATIONS = {
    'delete' => [->(scope) { scope }, :destroy!],
    'share' => [->(scope) { scope.succeeded.where(shared_at: nil) }, :share!],
    'unshare' => [->(scope) { scope.where.not(shared_at: nil) }, :unshare!],
    'link' => [->(scope) { scope.succeeded.where(public_token: nil) }, :create_public_link!],
    'unlink' => [->(scope) { scope.publicly_linked }, :revoke_public_link!]
  }.freeze

  before_action :set_generation, only: %i[show destroy retry update_share create_public_link revoke_public_link]
  before_action :set_cancellable_generation, only: :cancel

  def index
    scope = current_user.generations
    @kind_counts = scope.group(:kind).count
    @status_counts = scope.group(:status).count
    @shared_count, @public_count = sharing_counts(scope)
    set_filters

    @pagy, @generations = pagy(:offset, filtered_generations(scope), limit: PER_PAGE)
    # A bulk action (or a delete elsewhere) can empty the page we were on; fall back to the new last page.
    return unless @pagy.page > @pagy.last

    flash.keep # carry the bulk action's notice through this extra hop
    redirect_to results_return_path(page: @pagy.last)
  end

  # Applies one action to the results ticked in select mode on the Results page.
  def bulk
    operation = params[:operation].presence_in(BULK_OPERATIONS.keys)
    generations = current_user.generations.where(id: Array(params[:ids]))
    return redirect_to(results_return_path, alert: 'Select at least one result.', status: :see_other) \
      if operation.nil? || generations.none?

    count = apply_bulk(operation, generations)
    redirect_to results_return_path, notice: bulk_notice(operation, count), status: :see_other
  end

  def show
    PollGenerationJob.perform_later(@generation) if @generation.running?
  end

  def create
    @generation = current_user.generations.new(generation_params)
    assign_share_intent(@generation)
    attach_reused_reference(@generation)
    if @generation.save
      SubmitGenerationJob.perform_later(@generation)
      redirect_to kind_for(@generation).path, notice: 'Queued. Your result will appear below when it\'s ready.'
    else
      load_studio(kind_for(@generation), workflow_id: @generation.workflow_id)
      reapply_reference_after_failed_create
      render 'studios/show', status: :unprocessable_content
    end
  end

  def retry
    copy = current_user.generations.new(@generation.reusable_attributes)
    copy.input_image.attach(@generation.input_image.blob) if @generation.input_image.attached?
    if copy.save
      SubmitGenerationJob.perform_later(copy)
      redirect_to generation_path(copy), notice: 'Running it again.', status: :see_other
    else
      redirect_to generation_path(@generation), alert: copy.errors.full_messages.to_sentence, status: :see_other
    end
  end

  def update_share
    return head :unprocessable_content unless @generation.succeeded?

    if params[:share_result] == '1'
      @generation.share!
    else
      @generation.unshare!
    end

    respond_to_sharing_update
  end

  def create_public_link
    return head :unprocessable_content unless @generation.succeeded?

    @generation.create_public_link!
    respond_to_sharing_update(notice: 'Public link ready.')
  end

  def revoke_public_link
    @generation.revoke_public_link!
    respond_to_sharing_update(notice: 'Public link revoked.')
  end

  def destroy
    @generation.destroy!
    redirect_to generations_path, notice: 'Deleted.', status: :see_other
  end

  def cancel
    if GenerationCanceller.call(@generation).cancelled
      redirect_back_or_to queue_path, notice: 'Cancelled.', status: :see_other
    else
      redirect_back_or_to queue_path, alert: 'This job is no longer running.', status: :see_other
    end
  end

  private

  def set_filters
    @kind = params[:kind].presence_in(GenerationKind.keys)
    @status = params[:status].presence_in(Generation.statuses.keys)
    @shared = params[:shared] == '1'
    @public = params[:public] == '1'
  end

  def filtered_generations(scope)
    filtered = scope.recent.with_attached_outputs.with_attached_output_poster.with_album_art.includes(:workflow)
    filtered = filtered.where(kind: @kind) if @kind
    filtered = filtered.where(status: @status) if @status
    filtered = filtered.where.not(shared_at: nil) if @shared
    filtered = filtered.publicly_linked if @public
    filtered
  end

  def sharing_counts(scope)
    [scope.where.not(shared_at: nil).count, scope.publicly_linked.count]
  end

  def apply_bulk(operation, generations)
    applicable, action = BULK_OPERATIONS.fetch(operation)
    count = 0
    applicable.call(generations).find_each do |generation|
      generation.public_send(action)
      count += 1
    end
    count
  end

  def bulk_notice(operation, count)
    results = "#{count} #{'result'.pluralize(count)}"
    {
      'delete' => "Deleted #{results}.",
      'share' => "Shared #{results} with everyone.",
      'unshare' => "Stopped sharing #{results}.",
      'link' => "Created public links for #{results}.",
      'unlink' => "Revoked public links for #{results}."
    }.fetch(operation)
  end

  def results_return_path(page: params[:page])
    filters = params.permit(:kind, :status, :shared, :public).to_h
    generations_path(filters.merge(page: (page if page.to_i > 1)).compact_blank)
  end

  def set_generation
    @generation = current_user.generations.find(params[:id])
  end

  def set_cancellable_generation
    scope = current_user.admin? ? Generation.all : current_user.generations
    @generation = scope.find(params[:id])
  end

  def generation_params
    permitted = params.expect(generation: %i[workflow_id prompt negative_prompt seed aspect_ratio duration input_image
                                             quality cfg_level denoise lyrics batch_size pinned_backend_id])
    permitted[:denoise] = permitted[:denoise].to_f / 100.0 if permitted[:denoise].present?
    permitted
  end

  def kind_for(generation)
    generation.workflow&.kind_info || GenerationKind.find(generation.kind.presence || 'image')
  end

  def assign_share_intent(generation)
    raw = params[:generation] || {}
    generation.share_when_done = raw[:share_result] == '1'
  end

  def respond_to_sharing_update(notice: nil)
    respond_to do |format|
      format.turbo_stream { render :update_share }
      format.html do
        redirect_to generation_path(@generation), notice: notice || share_notice, status: :see_other
      end
    end
  end

  def share_notice
    @generation.shared? ? 'Shared with everyone.' : 'No longer shared.'
  end
end

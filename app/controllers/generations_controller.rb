# "Results": everything the user has generated, plus creating and re-running generations.
class GenerationsController < ApplicationController
  include StudioPage

  PER_PAGE = 24

  before_action :set_generation, only: %i[show destroy retry update_share]
  before_action :set_cancellable_generation, only: :cancel

  def index
    scope = current_user.generations
    @kind_counts = scope.group(:kind).count
    @status_counts = scope.group(:status).count
    @kind = params[:kind].presence_in(GenerationKind.keys)
    @status = params[:status].presence_in(Generation.statuses.keys)

    filtered = scope.recent.with_attached_outputs.includes(:workflow)
    filtered = filtered.where(kind: @kind) if @kind
    filtered = filtered.where(status: @status) if @status
    @pagy, @generations = pagy(:offset, filtered, limit: PER_PAGE)
  end

  def show
    PollGenerationJob.perform_later(@generation) if @generation.running?
  end

  def create
    @generation = current_user.generations.new(generation_params)
    assign_share_intent(@generation)
    if @generation.save
      SubmitGenerationJob.perform_later(@generation)
      redirect_to kind_for(@generation).path, notice: 'Queued. Your result will appear below when it\'s ready.'
    else
      load_studio(kind_for(@generation), workflow_id: @generation.workflow_id)
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
      @generation.share!(share_prompt: params[:share_prompt] == '1', share_input: params[:share_input] == '1')
    else
      @generation.unshare!
    end

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to generation_path(@generation), notice: share_notice, status: :see_other }
    end
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

  def set_generation
    @generation = current_user.generations.find(params[:id])
  end

  def set_cancellable_generation
    scope = current_user.admin? ? Generation.all : current_user.generations
    @generation = scope.find(params[:id])
  end

  def generation_params
    permitted = params.expect(generation: %i[workflow_id prompt negative_prompt seed aspect_ratio duration input_image
                                             quality cfg_level denoise lyrics batch_size])
    permitted[:denoise] = permitted[:denoise].to_f / 100.0 if permitted[:denoise].present?
    permitted
  end

  def kind_for(generation)
    generation.workflow&.kind_info || GenerationKind.find(generation.kind.presence || 'image')
  end

  def assign_share_intent(generation)
    raw = params[:generation] || {}
    generation.share_prompt = raw[:share_prompt] == '1'
    generation.share_input = raw[:share_input] == '1'
    generation.share_when_done = raw[:share_result] == '1'
  end

  def share_notice
    @generation.shared? ? 'Shared with everyone.' : 'No longer shared.'
  end
end

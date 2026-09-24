# "Results": everything the user has generated, plus creating and re-running generations.
class GenerationsController < ApplicationController
  include StudioPage

  PER_PAGE = 24

  before_action :set_generation, only: %i[show destroy retry share unshare]

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

  def show; end

  def create
    @generation = current_user.generations.new(generation_params)
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

  def share
    unless @generation.succeeded?
      return redirect_to generation_path(@generation), alert: 'Only finished results can be shared.', status: :see_other
    end

    @generation.share!(share_prompt: params[:share_prompt] == '1', share_input: params[:share_input] == '1')
    redirect_to generation_path(@generation), notice: 'Shared with everyone.', status: :see_other
  end

  def unshare
    @generation.unshare!
    redirect_to generation_path(@generation), notice: 'No longer shared.', status: :see_other
  end

  def destroy
    @generation.destroy!
    redirect_to generations_path, notice: 'Deleted.', status: :see_other
  end

  private

  def set_generation
    @generation = current_user.generations.find(params[:id])
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
end

# "Write a script" on the Video page: starts a VideoScriptJob, reports its progress, and cancels it.
class VideoScriptsController < ApplicationController
  include ChatPage

  before_action :load_chat_availability, only: :create
  before_action :set_script_request, only: %i[show destroy]

  def show
    render json: @script_request
  end

  def create
    return render json: { error: 'Chat is not available.' }, status: :service_unavailable unless chat_available?

    script = build_script
    if script.prompt.blank?
      return render json: { error: 'Describe the video first, then ask for a script.' },
                    status: :unprocessable_content
    end

    render json: start_request(script), status: :created
  end

  def destroy
    @script_request.with_lock { @script_request.cancelled! if @script_request.working? }
    render json: @script_request
  end

  private

  def build_script
    workflow = Workflow.enabled.where(kind: 'video').find(script_params[:workflow_id])
    Chat::VideoScript.new(prompt: script_params[:prompt], workflow:,
                          aspect_ratio: script_params[:aspect_ratio], duration: script_params[:duration])
  end

  def start_request(script)
    current_user.video_script_requests.stale.delete_all
    current_user.video_script_requests.create!(message: script.message).tap { VideoScriptJob.perform_later(it.id) }
  end

  def set_script_request
    @script_request = current_user.video_script_requests.find(params[:id])
  end

  def script_params
    params.expect(generation: %i[workflow_id prompt aspect_ratio duration])
  end
end

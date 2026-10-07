# Starts a chat that writes a video script from the studio's prompt, length and frame size.
class VideoScriptsController < ApplicationController
  include ChatPage

  before_action :load_chat_availability

  def create
    return redirect_to video_studio_path, alert: 'Chat is not available.', status: :see_other unless chat_available?

    workflow = Workflow.enabled.where(kind: 'video').find(script_params[:workflow_id])
    script = Chat::VideoScript.new(prompt: script_params[:prompt], workflow:,
                                   aspect_ratio: script_params[:aspect_ratio], duration: script_params[:duration])
    if script.prompt.blank?
      return redirect_to video_studio_path(workflow_id: workflow.id),
                         alert: 'Describe the video first, then ask for a script.', status: :see_other
    end

    redirect_to chat_path(start_conversation(script)), status: :see_other
  end

  private

  def start_conversation(script)
    conversation, reply = ChatConversation.transaction do
      conversation = current_user.chat_conversations.create!(model: default_chat_model, title: script.title)
      conversation.chat_messages.create!(role: :user, content: script.message)
      [conversation, conversation.chat_messages.create!(role: :assistant, status: :pending, content: '')]
    end
    ChatReplyJob.perform_later(reply.id)
    conversation
  end

  def script_params
    params.expect(generation: %i[workflow_id prompt aspect_ratio duration])
  end
end

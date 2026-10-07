# Asks the chat model for a video script, trying once more if the first attempt fails.
# The Video page polls the request and shows "retrying" between the two.
class VideoScriptJob < ApplicationJob
  queue_as :default

  def perform(script_request_id)
    script_request = VideoScriptRequest.find_by(id: script_request_id)
    attempt(script_request) while script_request&.working? && script_request.attempts_left?
  end

  private

  def attempt(script_request)
    script_request.update!(attempts: script_request.attempts + 1)
    script = LiteLlm::Client.complete(
      messages: [{ role: 'user', content: script_request.message }],
      model: AppSetting.current.chat_default_model.presence,
      audit: LiteLlm::Client::AuditContext.new(user: script_request.user, source: 'video_script')
    )
    finish(script_request, status: :succeeded, script: Chat::VideoScript.clean(script), error: nil)
  rescue LiteLlm::Error => e
    status = script_request.attempts_left? ? :retrying : :failed
    finish(script_request, status:, error: e.message)
  end

  # A cancel can land while the model is still answering; it wins.
  def finish(script_request, **attrs)
    script_request.with_lock do
      script_request.update!(attrs) if script_request.working?
    end
  end
end

# Checks whether ComfyUI has finished a running generation. When it has, downloads the
# outputs into Active Storage; otherwise re-enqueues itself until the generation times out.
class PollGenerationJob < ApplicationJob
  INTERVAL = 2.seconds

  queue_as :default

  def perform(generation)
    return unless generation.running?
    return generation.fail!('The backend for this generation was removed') if generation.backend.nil?

    client = generation.backend.client(read_timeout: 120)
    result = client.result(generation.comfy_prompt_id)
    return wait_or_time_out(generation) if result.pending?
    return generation.fail!(result.error_message) if result.error?

    collect_outputs(generation, client, result)
  rescue Comfyui::ConnectionError
    wait_or_time_out(generation)
  rescue Comfyui::Error => e
    generation.fail!(e.message)
  end

  private

  def wait_or_time_out(generation)
    return generation.fail!('Timed out waiting for ComfyUI to finish') if generation.timed_out?

    self.class.set(wait: INTERVAL).perform_later(generation)
  end

  def collect_outputs(generation, client, result)
    files = result.files
    if files.empty?
      return generation.fail!('The workflow finished without saving any output. Does it have a Save node?')
    end

    # Download everything before attaching so a dropped connection can't leave a partial set.
    downloads = files.map { |file| [file['filename'], client.download(file)] }
    downloads.each do |filename, data|
      generation.outputs.attach(io: StringIO.new(data), filename:, content_type: Marcel::MimeType.for(name: filename))
    end
    generation.update!(run_seconds: result.run_seconds) if result.run_seconds
    generation.succeed!
    generation.apply_pending_share!
  end
end

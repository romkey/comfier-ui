# Checks whether ComfyUI has finished a running generation. When it has, downloads the
# outputs into Active Storage; otherwise re-enqueues itself until the generation times out.
class PollGenerationJob < ApplicationJob # rubocop:disable Metrics/ClassLength
  INTERVAL = 2.seconds
  MAX_DOWNLOAD_ATTEMPTS = 5
  MISSING_HISTORY_AFTER = 2.minutes

  queue_as :default

  def perform(generation)
    requeue_in = nil
    finalize = false

    generation.with_lock do
      generation.reload
      return unless generation.running?

      requeue_in, finalize = poll(generation)
    end

    finalize_outputs!(generation) if finalize

    self.class.set(wait: requeue_in).perform_later(generation) if requeue_in
  end

  private

  def poll(generation)
    if generation.backend.nil?
      generation.fail!('The backend for this generation was removed')
      return [nil, false]
    end

    client = generation.backend.client(read_timeout: 120)
    prompt_id = generation.comfy_prompt_id
    result = client.result(prompt_id)

    return [requeue_or_fail_missing_history(generation, client, prompt_id, result), false] if result.pending?
    return [finish_with_error(generation, result), false] if result.error?

    collect_outputs(generation, client, result)
  rescue Comfyui::ConnectionError
    [requeue_or_time_out(generation), false]
  rescue Comfyui::Error => e
    generation.fail!(e.message)
    [nil, false]
  end

  def requeue_or_fail_missing_history(generation, client, prompt_id, _result)
    return requeue_or_time_out(generation) if client.prompt_in_queue?(prompt_id)

    # ComfyUI dropped the prompt from its queue; history can lag briefly behind.
    if generation.submitted_at&.< MISSING_HISTORY_AFTER.ago
      generation.fail!(
        'ComfyUI finished but Comfier never received the result. ' \
        'Check that the backend URL is reachable and history is available.'
      )
      return nil
    end

    requeue_or_time_out(generation)
  end

  def requeue_or_time_out(generation, wait: INTERVAL)
    if generation.timed_out?
      generation.fail!('Timed out waiting for ComfyUI to finish')
      return nil
    end

    wait
  end

  def finish_with_error(generation, result)
    generation.record_processing_times!(result)
    generation.fail!(result.error_message)
    nil
  end

  def finalize_outputs!(generation)
    verify_outputs_on_disk!(generation)

    generation.with_lock do
      generation.reload
      return unless generation.running?

      generation.succeed!
      generation.apply_pending_share!
    end
  rescue Comfyui::Error => e
    generation.fail!(e.message)
  end

  def collect_outputs(generation, client, result)
    if generation.outputs.attached? && outputs_on_disk?(generation)
      generation.record_processing_times!(result)
      generation.succeed! unless generation.succeeded?
      generation.apply_pending_share!
      return [nil, false]
    end

    generation.outputs.purge if generation.outputs.attached?

    files = result.files
    if files.empty?
      generation.record_processing_times!(result)
      generation.fail!('The workflow finished without saving any output. Does it have a Save node?')
      return [nil, false]
    end

    attach_outputs(generation, client, files)
    generation.record_processing_times!(result)
    generation.update!(parameters: generation.parameters.except('download_attempts'))
    [nil, true]
  rescue Comfyui::ConnectionError => e
    [handle_download_error(generation, e), false]
  end

  def attach_outputs(generation, client, files)
    downloads = files.map do |file|
      filename = file['filename']
      data = client.download(file)
      raise Comfyui::Error, "Downloaded #{filename} from #{generation.backend.name} is empty" if data.blank?

      [filename, data]
    end

    downloads.each do |filename, data|
      generation.outputs.attach(
        io: StringIO.new(data),
        filename:,
        content_type: Marcel::MimeType.for(name: filename)
      )
    end
  end

  def outputs_on_disk?(generation)
    generation.outputs.all? { |output| output.blob.service.exist?(output.blob.key) }
  end

  def verify_outputs_on_disk!(generation)
    return if outputs_on_disk?(generation)

    generation.outputs.purge
    raise Comfyui::Error,
          "Outputs were not saved to #{storage_root}. Sidekiq must mount the same storage path as web."
  end

  def storage_root
    service = ActiveStorage::Blob.service
    service.respond_to?(:root) ? service.root : Rails.root.join('storage')
  end

  def handle_download_error(generation, error)
    attempts = generation.parameters.fetch('download_attempts', 0) + 1
    generation.update!(parameters: generation.parameters.merge('download_attempts' => attempts))
    if attempts >= MAX_DOWNLOAD_ATTEMPTS
      generation.fail!("Couldn't download outputs from #{generation.backend.name}: #{error.message}")
      return nil
    end

    requeue_or_time_out(generation)
  end
end

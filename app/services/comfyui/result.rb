module Comfyui
  # A prompt's entry from ComfyUI's /history endpoint. ComfyUI only adds the entry once the
  # prompt has finished (successfully or not), so a missing entry means it's still queued or running.
  class Result
    def initialize(entry)
      @entry = entry
    end

    def pending? = @entry.nil?

    def error? = !pending? && @entry.dig('status', 'status_str') == 'error'

    def success? = !pending? && !error?

    def error_message
      messages = Array(@entry&.dig('status', 'messages'))
      _, data = messages.find { |type, _| type == 'execution_error' }
      return 'ComfyUI reported an error' unless data.is_a?(Hash)

      [data['node_type'], data['exception_message']].compact_blank.join(': ').strip
    end

    # Saved output files. Preview nodes write to "temp" and are skipped.
    def files
      return [] if pending?

      (@entry['outputs'] || {}).values.flat_map do |node_output|
        node_output.values.flat_map { Array(it) }.select do |file|
          file.is_a?(Hash) && file['filename'].present? && file.fetch('type', 'output') == 'output'
        end
      end.uniq
    end

    # Wall-clock run time from ComfyUI's execution_start and execution_success messages.
    def run_seconds
      return nil if pending?

      messages = Array(@entry.dig('status', 'messages'))
      started = message_timestamp(messages, 'execution_start')
      finished = message_timestamp(messages, 'execution_success') || message_timestamp(messages, 'execution_error')
      return nil unless started && finished

      (finished - started).clamp(0, Float::INFINITY)
    end

    private

    def message_timestamp(messages, type)
      _, data = messages.find { |message_type, _| message_type == type }
      return unless data.is_a?(Hash) && data['timestamp'].present?

      data['timestamp'].to_f / 1000.0
    end
  end
end

# Builds a still from the first frame of a finished video generation.
class ExtractVideoPosterJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS = 5
  RETRY_WAIT = 2.seconds

  def perform(generation, attempt = 0)
    generation.reload
    if missing_video_output?(generation) && attempt < MAX_ATTEMPTS
      self.class.set(wait: RETRY_WAIT).perform_later(generation, attempt + 1)
      return
    end

    VideoPosterExtractor.call(generation)
  end

  private

  def missing_video_output?(generation)
    generation.succeeded? && generation.video? && !generation.output_poster.attached? &&
      generation.outputs.none? { |output| output.content_type.to_s.start_with?('video/') }
  end
end

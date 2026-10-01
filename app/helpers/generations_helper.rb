module GenerationsHelper
  include AgentProgressHelper

  STATUS_BADGES = {
    'queued' => %w[secondary Queued],
    'running' => %w[primary Generating…],
    'succeeded' => %w[success Done],
    'failed' => %w[danger Failed],
    'cancelled' => %w[secondary Cancelled]
  }.freeze

  PROMPT_PLACEHOLDERS = {
    'image' => 'A lighthouse on a cliff at sunset, oil painting',
    'video' => 'Waves crashing against a lighthouse, slow drone shot',
    'audio' => 'Warm lo-fi piano loop with vinyl crackle',
    'model_3d' => 'A small wooden treasure chest'
  }.freeze

  def prompt_placeholder(kind) = PROMPT_PLACEHOLDERS.fetch(kind.key, '')

  def reference_image_label(kind)
    { 'image' => 'Reference image', 'video' => 'Starting frame', 'model_3d' => 'Picture of the object' }
      .fetch(kind.key, 'Starting image')
  end

  # Finished work is the common case, so it gets a quiet dot; anything else gets a labelled badge.
  def generation_cancellable?(generation)
    generation.in_progress? && (generation.user_id == current_user.id || current_user.admin?)
  end

  def generation_result_status(generation)
    generation.cancelled? ? 'cancelled' : generation.status
  end

  def generation_status(generation)
    return tag.span(class: 'status-dot status-success', title: 'Done') if generation.succeeded?

    color, label = STATUS_BADGES.fetch(generation_result_status(generation))
    tag.span(class: "badge text-bg-#{color}-subtle fw-medium") do
      safe_join([(tag.span(class: 'spinner-grow spinner-grow-sm me-1', aria: { hidden: true }) if generation.running?),
                 label].compact)
    end
  end

  def generation_shared_indicator(generation)
    return unless generation.shared?

    tag.span(class: 'result-shared', title: 'Shared') do
      tag.i(class: 'bi bi-share-fill', aria: { hidden: true })
    end
  end

  def video_poster_url(generation)
    return unless generation.output_poster.attached?

    rails_blob_path(generation.output_poster, disposition: 'inline')
  end

  def result_media_preview(generation)
    output = primary_result_output(generation)
    if generation.succeeded? && output&.content_type.to_s.start_with?('video/') && generation.output_poster.attached?
      tag.div(class: 'result-video-poster') do
        safe_join([
          image_tag(video_poster_url(generation), alt: '', class: 'output-media', loading: 'lazy'),
          tag.span(class: 'result-play', aria: { hidden: true }) { tag.i(class: 'bi bi-play-fill') }
        ])
      end
    elsif output
      output_preview(output, poster_url: video_poster_url(generation))
    elsif generation.in_progress?
      tag.div(class: 'result-placeholder') do
        tag.div(class: 'spinner-border spinner-border-sm text-secondary', role: 'status') do
          tag.span('Generating', class: 'visually-hidden')
        end
      end
    elsif generation.cancelled?
      tag.div(class: 'result-placeholder text-secondary') do
        tag.i(class: 'bi bi-slash-circle fs-4', aria: { hidden: true })
      end
    else
      tag.div(class: 'result-placeholder text-secondary') do
        tag.i(class: 'bi bi-exclamation-octagon fs-4', aria: { hidden: true })
      end
    end
  end

  def public_output_preview(generation, attachment, index, controls: false)
    url = public_share_output_path(generation.public_token, index)
    poster = video_poster_url(generation) if attachment.content_type.to_s.start_with?('video/')
    case attachment.content_type
    when %r{\Aimage/} then image_tag(url, alt: '', class: 'output-media', loading: 'lazy')
    when %r{\Avideo/}
      video_tag(url, class: 'output-media', controls:, poster:, muted: !controls, loop: true, playsinline: true,
                     preload: 'metadata')
    when %r{\Aaudio/} then audio_tag(url, controls: true, class: 'w-100', preload: 'metadata')
    else file_output(attachment)
    end
  end

  def output_preview(attachment, controls: false, poster_url: nil)
    url = rails_blob_path(attachment, disposition: 'inline')
    case attachment.content_type
    when %r{\Aimage/} then image_tag(url, alt: attachment.filename.to_s, class: 'output-media', loading: 'lazy')
    when %r{\Avideo/}
      video_tag(url, class: 'output-media', controls:, poster: poster_url, muted: !controls, loop: true,
                     playsinline: true, preload: 'metadata')
    when %r{\Aaudio/} then audio_tag(url, controls: true, class: 'w-100', preload: 'metadata')
    else file_output(attachment)
    end
  end

  def file_output(attachment)
    tag.div(class: 'output-file') do
      safe_join([tag.i(class: 'bi bi-box fs-2 text-secondary', aria: { hidden: true }),
                 tag.span(attachment.filename.to_s, class: 'text-12 text-secondary text-truncate mw-100')])
    end
  end

  def primary_result_output(generation)
    return unless generation.succeeded?

    generation.outputs.find { |output| output.content_type.to_s.start_with?('video/') } ||
      generation.outputs.find { |output| output.content_type.to_s.start_with?('image/') } ||
      generation.outputs.first
  end

  def generation_parameters(generation)
    params = generation.parameters.slice('aspect_ratio', 'width', 'height', 'duration', 'frames', 'seed', 'quality',
                                         'cfg_level', 'denoise', 'batch_size', 'steps', 'cfg')
    labels = { 'aspect_ratio' => 'Aspect ratio', 'duration' => 'Length', 'cfg_level' => 'Prompt strength',
               'batch_size' => 'How many' }
    params.to_h do |key, value|
      value = "#{value}s" if key == 'duration'
      value = "#{(value.to_f * 100).round}%" if key == 'denoise'
      value = value.to_s.capitalize if key == 'quality'
      [labels.fetch(key, key.humanize), value]
    end
  end
end

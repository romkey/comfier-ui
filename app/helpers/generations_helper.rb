module GenerationsHelper
  STATUS_BADGES = {
    'queued' => %w[secondary Queued],
    'running' => %w[primary Generating…],
    'succeeded' => %w[success Done],
    'failed' => %w[danger Failed]
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

  def generation_status(generation)
    return tag.span(class: 'status-dot status-success', title: 'Done') if generation.succeeded?

    color, label = STATUS_BADGES.fetch(generation.status)
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

  def output_preview(attachment, controls: false)
    url = rails_blob_path(attachment, disposition: 'inline')
    case attachment.content_type
    when %r{\Aimage/} then image_tag(url, alt: attachment.filename.to_s, class: 'output-media', loading: 'lazy')
    when %r{\Avideo/}
      video_tag(url, class: 'output-media', controls:, muted: !controls, loop: true, playsinline: true,
                     preload: 'metadata')
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

# Resolves form values into the parameters stored on a generation and substituted into workflows.
module GenerationParameters
  extend ActiveSupport::Concern

  private

  def resolve_parameters
    return if workflow.nil?

    self.kind = workflow.kind
    share_later = share_when_done?
    stored_lyrics = lyrics if workflow.uses?(:lyrics)
    self.parameters = resolved_seed_entry.merge(optional_parameters)
    self.parameters['lyrics'] = stored_lyrics.to_s if workflow.uses?(:lyrics)
    self.share_when_done = true if share_later
  end

  def optional_parameters
    {
      width: :resolved_dimensions, height: :resolved_dimensions,
      duration: :resolved_timing, frames: :resolved_timing,
      steps: :resolved_quality, cfg: :resolved_cfg,
      denoise: :resolved_denoise, batch_size: :resolved_batch
    }.each_with_object({}) do |(placeholder, method), params|
      params.merge!(send(method)) if workflow.uses?(placeholder)
    end
  end

  def resolved_seed_entry
    workflow.uses?(:seed) ? { 'seed' => resolved_seed } : {}
  end

  def resolved_seed
    seed.present? ? seed.to_i.clamp(0, Generation::MAX_SEED) : SecureRandom.random_number(Generation::MAX_SEED)
  end

  def resolved_dimensions
    ratio = Generation::ASPECT_RATIOS.include?(aspect_ratio) ? aspect_ratio : user&.default_aspect_ratio || '1:1'
    width, height = self.class.dimensions_for(ratio, workflow.base_resolution)
    { 'aspect_ratio' => ratio, 'width' => width, 'height' => height }
  end

  def resolved_timing
    seconds = (duration.presence || kind_info.default_duration || 5).to_f.clamp(Generation::DURATION_RANGE.min,
                                                                                Generation::DURATION_RANGE.max)
    {
      'duration' => (seconds % 1).zero? ? seconds.to_i : seconds.round(1),
      'frames' => (seconds * workflow.frame_rate).round + 1
    }
  end

  def resolved_quality
    level = Generation::QUALITIES.include?(quality) ? quality : 'standard'
    factor = { 'fast' => 0.5, 'best' => 1.5 }.fetch(level, 1.0)
    { 'quality' => level, 'steps' => (workflow.steps * factor).round.clamp(1, 150) }
  end

  def resolved_cfg
    level = Generation::CFG_LEVELS.include?(cfg_level) ? cfg_level : 'balanced'
    factor = { 'loose' => 0.7, 'strict' => 1.3 }.fetch(level, 1.0)
    { 'cfg_level' => level, 'cfg' => (workflow.guidance * factor).round(1).clamp(0.1, 30.0) }
  end

  def resolved_denoise
    value = denoise.present? ? denoise.to_f : 0.6
    { 'denoise' => value.clamp(Generation::DENOISE_RANGE.min, Generation::DENOISE_RANGE.max).round(2) }
  end

  def resolved_batch
    size = batch_size.present? ? batch_size.to_i : 1
    { 'batch_size' => size.clamp(Generation::BATCH_RANGE.min, Generation::BATCH_RANGE.max) }
  end
end

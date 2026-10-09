# How an mflux or MLX video workflow describes a run, in place of a ComfyUI graph: the command to run
# and its options, with the same {{placeholders}}. Option keys are the command's flags in snake_case
# ("image_strength" is --image-strength, true is a bare flag). The agent passes them through, so a new
# flag needs no Comfier change.
#
#   { "command": "mflux-generate-z-image-turbo", "model": "z-image-turbo", "quantize": 8,
#     "prompt": "{{prompt}}", "width": "{{width}}", "height": "{{height}}", "steps": "{{steps}}",
#     "seed": "{{seed}}", "min_memory_gb": 16 }
#
# `min_memory_gb` isn't passed on: servers with less memory than this aren't offered the style.
module EngineRecipe
  COMMANDS = {
    'mflux' => /\Amflux-generate[a-z0-9.-]*\z/,
    'mlx_video' => /\Amlx_video(\.[a-z0-9_]+)+\z/
  }.freeze
  COMMAND_HINTS = {
    'mflux' => 'an mflux command such as mflux-generate-z-image-turbo',
    'mlx_video' => 'an mlx-video module such as mlx_video.ltx_2.generate'
  }.freeze
  KEY = /\A[a-z][a-z0-9_]*\z/
  # The Gemma 3 text encoder LTX-2.3 is known to work with in mlx-video.
  LTX_TEXT_ENCODER = 'mlx-community/gemma-3-12b-it-bf16'.freeze
  BROKEN_TEXT_ENCODER = 'Lightricks/LTX-2'.freeze
  HF_REPO = %r{\A[A-Za-z0-9][\w.-]*/[\w.-]+\z}
  # Options the agent sets itself; a recipe can't point them somewhere else.
  RESERVED_OPTIONS = %w[output output_path output_dir].freeze
  MAX_KEYS = 64

  module_function

  def problems(engine, recipe)
    return ['must be a JSON object'] unless recipe.is_a?(Hash) && recipe.any?

    required_problems(engine, recipe) + option_problems(recipe)
  end

  def required_problems(engine, recipe)
    found = []
    found << command_problem(engine, recipe['command']) unless valid_command?(engine, recipe['command'])
    found << 'needs "model"' if engine == 'mflux' && !recipe['model'].is_a?(String)
    found.concat(mlx_video_model_problems(recipe)) if engine == 'mlx_video'
    found << "has too many options (#{recipe.size})" if recipe.size > MAX_KEYS
    found
  end

  # mlx-video has no --model: LTX loads model_repo (a Hugging Face owner/name), Wan a local model_dir.
  def mlx_video_model_problems(recipe)
    found = []
    if recipe.key?('model')
      found << 'can\'t use "model" for MLX video; name the Hugging Face repo with "model_repo" ' \
               '(e.g. prince-canuma/LTX-2.3-distilled) or a converted Wan model with "model_dir"'
    end
    %w[model_repo text_encoder_repo].each do |key|
      repo = recipe[key]
      found << "\"#{key}\" must be a Hugging Face repo (owner/name), not #{repo.inspect}" if repo && !repo?(repo)
    end
    found.concat(ltx_text_encoder_problems(recipe))
  end

  # LTX-2.3 conversions ship without their Gemma text encoder, so mlx-video needs one named. Lightricks/LTX-2
  # loads the wrong tokenizer and every prompt gives the same video (Blaizzy/mlx-video#26).
  def ltx_text_encoder_problems(recipe)
    return [] unless recipe['command'].to_s.start_with?('mlx_video.ltx_2.')

    encoder = recipe['text_encoder_repo']
    if encoder.to_s.casecmp?(BROKEN_TEXT_ENCODER)
      ["can't use #{BROKEN_TEXT_ENCODER} as \"text_encoder_repo\" (every prompt gives the same video); " \
       "use #{LTX_TEXT_ENCODER}"]
    elsif encoder.blank? && ltx_23?(recipe)
      ["needs \"text_encoder_repo\": LTX-2.3 doesn't include its text encoder (use #{LTX_TEXT_ENCODER})"]
    else
      []
    end
  end

  def ltx_23?(recipe) = recipe['model_repo'].to_s.match?(/LTX-2\.3/i)

  def repo?(value) = value.is_a?(String) && value.match?(HF_REPO)

  def valid_command?(engine, command) = command.is_a?(String) && command.match?(COMMANDS.fetch(engine))

  # A recipe for another engine (say an mflux preset under Runs on: MLX video) says which one it's for.
  def command_problem(engine, command)
    other = COMMANDS.keys.find { it != engine && valid_command?(it, command) }
    return "needs \"command\": #{COMMAND_HINTS.fetch(engine)}" unless other

    label = WorkflowEngine.label_for(other)
    "is for #{label} (#{command}); set Runs on to #{label}, or choose from the " \
      "#{WorkflowEngine.label_for(engine)} presets"
  end

  def option_problems(recipe)
    recipe.except('command').flat_map do |key, value|
      next ["option \"#{key}\" isn't a flag name (lowercase letters, digits and _)"] unless key.match?(KEY)
      next ["\"#{key}\" is set by the agent"] if RESERVED_OPTIONS.include?(key)
      next [] if scalar?(value) || (value.is_a?(Array) && value.all? { scalar?(it) })

      ["option \"#{key}\" must be a string, number, true/false, or a list of those"]
    end
  end

  def scalar?(value) = value.is_a?(String) || value.is_a?(Numeric) || [true, false].include?(value)

  def min_memory_gb(recipe)
    value = recipe.is_a?(Hash) ? recipe['min_memory_gb'] : nil
    value.is_a?(Numeric) && value.positive? ? value : nil
  end

  # The model a recipe loads, for availability and the server's model list: an mflux model name, or the
  # Hugging Face repo an mlx-video recipe loads. A local model_dir isn't something Comfier can check.
  # mflux names its model with "model"; MLX video with "model_repo" (a local model_dir isn't something
  # Comfier can check or download).
  def model(recipe, engine = nil)
    return unless recipe.is_a?(Hash)

    key = engine.to_s == 'mlx_video' ? 'model_repo' : 'model'
    key = 'model_repo' if engine.nil? && recipe['model'].blank?
    recipe[key].presence&.to_s
  end

  # Everything the recipe needs downloaded: the model, and for MLX video its text encoder.
  def models(recipe, engine)
    return [] unless recipe.is_a?(Hash)

    extra = engine.to_s == 'mlx_video' ? recipe['text_encoder_repo'].presence&.to_s : nil
    [model(recipe, engine), extra].compact.uniq
  end
end

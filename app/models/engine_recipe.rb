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
    found << "needs \"command\": #{COMMAND_HINTS.fetch(engine)}" unless valid_command?(engine, recipe['command'])
    found << 'needs "model"' if engine == 'mflux' && !recipe['model'].is_a?(String)
    found << "has too many options (#{recipe.size})" if recipe.size > MAX_KEYS
    found
  end

  def valid_command?(engine, command) = command.is_a?(String) && command.match?(COMMANDS.fetch(engine))

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

  # The model a recipe loads, for availability and the server's model list.
  def model(recipe) = recipe.is_a?(Hash) ? recipe['model'].presence&.to_s : nil
end

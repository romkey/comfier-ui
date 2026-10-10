# Starting recipes for mflux and MLX video workflows, offered on the admin workflow form. Memory
# figures are rough guides (LTX-2.3 is a 22B video model plus a 12B Gemma text encoder, in bf16); edit
# `min_memory_gb` in the recipe to match your Macs.
class EnginePreset
  # `settings` are the style's own fields (steps, guidance, frame_rate) the form fills in with the recipe.
  Preset = Data.define(:engine, :key, :label, :kind, :recipe, :settings) do
    def initialize(settings: {}, **) = super

    def to_json_text = JSON.pretty_generate(recipe)
  end

  IMAGE = {
    'prompt' => '{{prompt}}', 'width' => '{{width}}', 'height' => '{{height}}', 'seed' => '{{seed}}'
  }.freeze

  # LTX-2.3 makes 24 fps video. Frames are counted at the style's frame rate and written at {{fps}}, so the two
  # always agree (a 16 fps count played at 24 runs fast and jerky). The x2 1.1 upscaler replaces 1.0, which
  # mlx-video would otherwise pick first.
  LTX_DISTILLED = {
    'command' => 'mlx_video.ltx_2.generate', 'pipeline' => 'distilled',
    'model_repo' => 'prince-canuma/LTX-2.3-distilled', 'text_encoder_repo' => EngineRecipe::LTX_TEXT_ENCODER,
    'spatial_upscaler' => EngineRecipe::LTX_SPATIAL_UPSCALER
  }.freeze
  LTX_VIDEO = {
    'width' => '{{width}}', 'height' => '{{height}}', 'num_frames' => '{{frames}}', 'fps' => '{{fps}}',
    'seed' => '{{seed}}', 'min_memory_gb' => 96
  }.freeze
  LTX_SETTINGS = { 'frame_rate' => 24 }.freeze

  ALL = [
    Preset.new(engine: 'mflux', key: 'z-image-turbo', label: 'Z-Image Turbo (fast, 16 GB)', kind: 'image', recipe: {
                 'command' => 'mflux-generate-z-image-turbo', 'model' => 'z-image-turbo', 'quantize' => 8,
                 'steps' => 9, **IMAGE, 'min_memory_gb' => 16
               }),
    Preset.new(engine: 'mflux', key: 'flux2-klein-4b', label: 'FLUX.2 Klein 4B (16 GB)', kind: 'image', recipe: {
                 'command' => 'mflux-generate-flux2', 'model' => 'flux2-klein-4b', 'quantize' => 8,
                 'steps' => '{{steps}}', **IMAGE, 'min_memory_gb' => 16
               }),
    Preset.new(engine: 'mflux', key: 'flux1-dev', label: 'FLUX.1 dev (24 GB)', kind: 'image', recipe: {
                 'command' => 'mflux-generate', 'model' => 'dev', 'quantize' => 8, 'steps' => '{{steps}}',
                 'guidance' => '{{cfg}}', **IMAGE, 'min_memory_gb' => 24
               }),
    Preset.new(engine: 'mflux', key: 'flux1-dev-img2img', label: 'FLUX.1 dev from a reference image (24 GB)',
               kind: 'image', recipe: {
                 'command' => 'mflux-generate', 'model' => 'dev', 'quantize' => 8, 'steps' => '{{steps}}',
                 'guidance' => '{{cfg}}', **IMAGE, 'image' => ['{{image}}', '{{denoise}}'], 'min_memory_gb' => 24
               }),
    Preset.new(engine: 'mflux', key: 'qwen-image', label: 'Qwen-Image (48 GB)', kind: 'image', recipe: {
                 'command' => 'mflux-generate-qwen', 'model' => 'qwen-image', 'quantize' => 8,
                 'steps' => '{{steps}}', 'guidance' => '{{cfg}}', 'negative_prompt' => '{{negative_prompt}}',
                 **IMAGE, 'min_memory_gb' => 48
               }),
    Preset.new(engine: 'mflux', key: 'qwen-image-edit', label: 'Qwen-Image Edit (48 GB)', kind: 'image', recipe: {
                 'command' => 'mflux-generate-qwen-edit', 'model' => 'qwen-image-edit', 'quantize' => 8,
                 'steps' => '{{steps}}', 'guidance' => '{{cfg}}', 'prompt' => '{{prompt}}',
                 'image_paths' => ['{{image}}'], 'seed' => '{{seed}}', 'min_memory_gb' => 48
               }),
    Preset.new(engine: 'mlx_video', key: 'ltx-2.3-distilled', label: 'LTX-2.3 distilled (fast, 96 GB)', kind: 'video',
               recipe: { **LTX_DISTILLED, 'prompt' => '{{prompt}}', **LTX_VIDEO }, settings: LTX_SETTINGS),
    Preset.new(engine: 'mlx_video', key: 'ltx-2.3-distilled-i2v', label: 'LTX-2.3 distilled, from an image (96 GB)',
               kind: 'video', settings: LTX_SETTINGS,
               recipe: { **LTX_DISTILLED, 'prompt' => '{{prompt}}', 'image' => '{{image}}', **LTX_VIDEO }),
    # Dev at half size with guidance, then upscaled and refined with the distilled LoRA (in the dev repo), as
    # ComfyUI's LTX-2.3 templates do. Plain "dev" renders full size in one pass and looks much worse.
    Preset.new(engine: 'mlx_video', key: 'ltx-2.3-dev', label: 'LTX-2.3 dev, two-stage (higher quality, 96 GB)',
               kind: 'video', recipe: {
                 'command' => 'mlx_video.ltx_2.generate', 'pipeline' => 'dev-two-stage',
                 'model_repo' => 'prince-canuma/LTX-2.3-dev', 'text_encoder_repo' => EngineRecipe::LTX_TEXT_ENCODER,
                 'spatial_upscaler' => EngineRecipe::LTX_SPATIAL_UPSCALER, 'prompt' => '{{prompt}}',
                 'negative_prompt' => '{{negative_prompt}}', 'cfg_scale' => '{{cfg}}', 'steps' => '{{steps}}',
                 **LTX_VIDEO
               }, settings: { **LTX_SETTINGS, 'guidance' => 3.0, 'steps' => 30 }),
    # Wan2.2 TI2V 5B writes 24 fps video (it has no fps flag), so frames are counted at 24.
    Preset.new(engine: 'mlx_video', key: 'wan-2.2-ti2v-5b', label: 'Wan2.2 TI2V 5B (converted weights, 32 GB)',
               kind: 'video', recipe: {
                 'command' => 'mlx_video.wan_2.generate', 'model_dir' => '~/.comfier/models/wan22_ti2v_5b_mlx',
                 'prompt' => '{{prompt}}', 'negative_prompt' => '{{negative_prompt}}', 'width' => '{{width}}',
                 'height' => '{{height}}', 'num_frames' => '{{frames}}', 'steps' => '{{steps}}',
                 'guide_scale' => '{{cfg}}', 'seed' => '{{seed}}', 'min_memory_gb' => 32
               }, settings: { 'frame_rate' => 24 })
  ].freeze

  def self.all = ALL
  def self.for_engine(engine) = ALL.select { it.engine == engine.to_s }
end

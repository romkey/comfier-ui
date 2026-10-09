# Starting recipes for mflux and MLX video workflows, offered on the admin workflow form. Memory
# figures are rough guides for 8-bit weights; edit `min_memory_gb` in the recipe to match your Macs.
class EnginePreset
  Preset = Data.define(:engine, :key, :label, :kind, :recipe) do
    def to_json_text = JSON.pretty_generate(recipe)
  end

  IMAGE = {
    'prompt' => '{{prompt}}', 'width' => '{{width}}', 'height' => '{{height}}', 'seed' => '{{seed}}'
  }.freeze

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
    Preset.new(engine: 'mlx_video', key: 'ltx-2.3-distilled', label: 'LTX-2.3 distilled (fast, 64 GB)', kind: 'video',
               recipe: {
                 'command' => 'mlx_video.ltx_2.generate', 'pipeline' => 'distilled',
                 'model_repo' => 'prince-canuma/LTX-2.3-distilled', 'prompt' => '{{prompt}}',
                 'width' => '{{width}}', 'height' => '{{height}}', 'num_frames' => '{{frames}}', 'fps' => 24,
                 'seed' => '{{seed}}', 'min_memory_gb' => 64
               }),
    Preset.new(engine: 'mlx_video', key: 'ltx-2.3-distilled-i2v', label: 'LTX-2.3 distilled, from an image (64 GB)',
               kind: 'video', recipe: {
                 'command' => 'mlx_video.ltx_2.generate', 'pipeline' => 'distilled',
                 'model_repo' => 'prince-canuma/LTX-2.3-distilled', 'prompt' => '{{prompt}}', 'image' => '{{image}}',
                 'width' => '{{width}}', 'height' => '{{height}}', 'num_frames' => '{{frames}}', 'fps' => 24,
                 'seed' => '{{seed}}', 'min_memory_gb' => 64
               }),
    Preset.new(engine: 'mlx_video', key: 'ltx-2.3-dev', label: 'LTX-2.3 dev (higher quality, 64 GB)', kind: 'video',
               recipe: {
                 'command' => 'mlx_video.ltx_2.generate', 'pipeline' => 'dev',
                 'model_repo' => 'prince-canuma/LTX-2.3-dev', 'prompt' => '{{prompt}}',
                 'negative_prompt' => '{{negative_prompt}}', 'cfg_scale' => '{{cfg}}', 'steps' => '{{steps}}',
                 'width' => '{{width}}', 'height' => '{{height}}', 'num_frames' => '{{frames}}', 'fps' => 24,
                 'seed' => '{{seed}}', 'min_memory_gb' => 64
               }),
    Preset.new(engine: 'mlx_video', key: 'wan-2.2-ti2v-5b', label: 'Wan2.2 TI2V 5B (converted weights, 32 GB)',
               kind: 'video', recipe: {
                 'command' => 'mlx_video.wan_2.generate', 'model_dir' => '~/.comfier/models/wan22_ti2v_5b_mlx',
                 'prompt' => '{{prompt}}', 'negative_prompt' => '{{negative_prompt}}', 'width' => '{{width}}',
                 'height' => '{{height}}', 'num_frames' => '{{frames}}', 'steps' => '{{steps}}',
                 'guide_scale' => '{{cfg}}', 'seed' => '{{seed}}', 'min_memory_gb' => 32
               })
  ].freeze

  def self.all = ALL
  def self.for_engine(engine) = ALL.select { it.engine == engine.to_s }
end

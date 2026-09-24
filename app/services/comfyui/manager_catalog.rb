module Comfyui
  # Where ComfyUI-Manager would put a catalog entry, as the "folder/file" path Comfier uses for model requirements.
  # Entries either name a models folder, optionally with a subfolder ("checkpoints/SD1.5"), or say "default" to use
  # the usual folder for their type.
  module ManagerCatalog
    DEFAULT_FOLDERS = {
      'checkpoint' => 'checkpoints', 'unclip' => 'checkpoints', 'diffusion_model' => 'diffusion_models',
      'vae' => 'vae', 'lora' => 'loras', 'clip' => 'text_encoders', 'clip_vision' => 'clip_vision',
      'controlnet' => 'controlnet', 't2i-adapter' => 'controlnet', 'upscale' => 'upscale_models',
      'embedding' => 'embeddings', 'gligen' => 'gligen', 'taesd' => 'vae_approx'
    }.freeze

    module_function

    def path(entry)
      filename = entry['filename'].to_s
      save_path = entry['save_path'].to_s
      folder = save_path == 'default' ? DEFAULT_FOLDERS[entry['type'].to_s.downcase] : save_path
      return if filename.empty? || folder.blank?

      directory, *subfolders = folder.split('/')
      requirement = ModelRequirement.new(directory:, name: [*subfolders, filename].join('/'))
      requirement.path if requirement.problems.empty?
    end
  end
end

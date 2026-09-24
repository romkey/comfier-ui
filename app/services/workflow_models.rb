# Works out which model files a workflow needs.
#
# API-format exports keep the file names that loader nodes use but lose the download links, so
# requirements are inferred from well-known loader inputs. UI-format exports (and ComfyUI's built-in
# templates) record `properties.models` on each loader node with a direct link, so those can be
# imported to fill the links in.
module WorkflowModels
  EXTENSIONS = %w[.safetensors .sft .ckpt .pt .pt2 .pth .bin .gguf .onnx].freeze

  INPUT_DIRECTORIES = {
    'ckpt_name' => 'checkpoints',
    'unet_name' => 'diffusion_models',
    'vae_name' => 'vae',
    'clip_name' => 'text_encoders',
    'clip_name1' => 'text_encoders',
    'clip_name2' => 'text_encoders',
    'clip_name3' => 'text_encoders',
    'clip_name4' => 'text_encoders',
    'lora_name' => 'loras',
    'control_net_name' => 'controlnet',
    'style_model_name' => 'style_models',
    'gligen_name' => 'gligen',
    'hypernetwork_name' => 'hypernetworks',
    'audio_encoder_name' => 'audio_encoders'
  }.freeze

  # Inputs whose folder depends on the node, not just the input name.
  NODE_INPUT_DIRECTORIES = {
    %w[CLIPVisionLoader clip_name] => 'clip_vision',
    %w[UpscaleModelLoader model_name] => 'upscale_models'
  }.freeze

  module_function

  def infer(graph)
    return [] unless graph.is_a?(Hash)

    requirements = graph.values.flat_map do |node|
      next [] unless node.is_a?(Hash) && node['inputs'].is_a?(Hash)

      node['inputs'].filter_map { |input, value| requirement_for(node['class_type'], input, value) }
    end
    merge(requirements)
  end

  def ui_format?(data) = data.is_a?(Hash) && data['nodes'].is_a?(Array)

  def from_ui_workflow(data)
    return [] unless ui_format?(data)

    subgraph_nodes = Array(data.dig('definitions', 'subgraphs')).flat_map { Array(it['nodes']) }
    requirements = (data['nodes'] + subgraph_nodes).flat_map do |node|
      Array(node.dig('properties', 'models')).filter_map do |model|
        next unless model.is_a?(Hash) && model['name'].present? && model['directory'].present?

        ModelRequirement.new(directory: model['directory'], name: model['name'], url: model['url'])
      end
    end
    merge(requirements)
  end

  # Combines lists, keeping the first occurrence of each file and filling in missing download links.
  def merge(*lists)
    lists.flatten.each_with_object({}) do |requirement, merged|
      existing = merged[requirement.key]
      merged[requirement.key] = if existing.nil?
                                  requirement
                                else
                                  (existing.url ? existing : existing.with_url(requirement.url))
                                end
    end.values
  end

  def requirement_for(class_type, input, value)
    return unless value.is_a?(String) && !value.match?(Workflow::PLACEHOLDER)
    return unless EXTENSIONS.include?(File.extname(value).downcase)

    directory = NODE_INPUT_DIRECTORIES[[class_type, input]] || INPUT_DIRECTORIES[input]
    ModelRequirement.new(directory:, name: value) if directory
  end
end

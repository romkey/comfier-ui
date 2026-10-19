# frozen_string_literal: true

module Agent
  # Apple Silicon runs ComfyUI on PyTorch's MPS device, which can't hold fp8 tensors, so there an fp8 model is
  # swapped for an fp16 one: a copy already on the server, else the official fp16 file when its link exists
  # (EnrichWorkflowModelsJob looks), else the fp8 file, converted by the agent as it downloads. Jobs sent to
  # the server name the stand-ins instead.
  class MacWeights
    FP8 = /fp8/i
    FP8_TOKEN = /fp8(?:_e4m3fn|_e5m2)?(?:_scaled)?(?:_fast)?/i
    CONVERT = 'fp8_to_fp16'
    # The first agent that understands `convert` on model.download.
    CONVERTING_AGENT = Gem::Version.new('0.4.13')

    class << self
      def fp8?(filename) = File.basename(filename.to_s).match?(FP8)
      def convertible?(filename) = fp8?(filename) && File.extname(filename.to_s).casecmp?('.safetensors')

      # wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors -> wan2.2_t2v_high_noise_14B_fp16.safetensors
      def fp16_name(filename)
        dir, base = File.split(filename)
        name = base.sub(FP8_TOKEN, 'fp16')
        dir == '.' ? name : File.join(dir, name)
      end

      def converted_name(filename) = fp16_name(filename).sub(/\.safetensors\z/i, '_from_fp8.safetensors')

      # The fp16 file's link, by the same rename, when the link ends in the fp8 file's name.
      def fp16_url_guess(url, filename)
        base = File.basename(filename)
        uri = URI.parse(url.to_s)
        return unless uri.path.to_s.end_with?("/#{base}")

        uri.path = uri.path.delete_suffix(base) + File.basename(fp16_name(filename))
        uri.to_s
      rescue URI::InvalidURIError
        nil
      end
    end

    def initialize(backend)
      @backend = backend
    end

    def active? = @backend.apple_silicon?

    # The models a workflow needs on this server, with fp8 files swapped for their stand-ins.
    def models(models) = models.map { substitute(it) || it }

    # The fp16 stand-in for an fp8 model, or nil when the model isn't fp8 or has none here.
    def substitute(model)
      return unless active? && self.class.convertible?(model['filename'])

      on_server(model) || official(model) || converted(model)
    end

    # Why an fp8 model can't run here, or nil.
    def problem(model)
      return unless active? && self.class.fp8?(model['filename']) && substitute(model).nil?

      file = File.basename(model['filename'])
      return "#{file} is fp8, which Apple Silicon can't run; use an fp16 or GGUF version" unless
        self.class.convertible?(model['filename']) && model['url'].present?

      "#{file} is fp8, which Apple Silicon can't run; update the agent on #{@backend.name} so it can convert it"
    end

    # The graph with fp8 filenames swapped for their stand-ins and fp8 weight_dtype choices set to default.
    def rewrite(graph, models)
      return graph unless active? && graph.is_a?(Hash)

      renames = models.each_with_object({}) do |model, map|
        swapped = substitute(model)
        map[model['filename']] = swapped['filename'] if swapped
      end
      graph.transform_values { rewrite_node(it, renames) }
    end

    private

    def rewrite_node(node, renames)
      return node unless node.is_a?(Hash) && node['inputs'].is_a?(Hash)

      inputs = node['inputs'].to_h do |input, value|
        next [input, value] unless value.is_a?(String)
        next [input, 'default'] if input == 'weight_dtype' && value.match?(FP8)

        [input, renames.fetch(value.tr('\\', '/'), value)]
      end
      node.merge('inputs' => inputs)
    end

    def matcher = @matcher ||= ModelMatcher.new(@backend.backend_models.pluck(:folder, :filename))

    def on_server(model)
      name = [self.class.fp16_name(model['filename']), self.class.converted_name(model['filename'])]
             .find { matcher.present?(model['folder'], it) }
      stand_in(model, name, {}) if name
    end

    def official(model)
      return if model['fp16_url'].blank?

      stand_in(model, self.class.fp16_name(model['filename']),
               'url' => model['fp16_url'], 'bytes' => model['fp16_bytes'], 'sha256' => model['fp16_sha256'])
    end

    # Downloads the fp8 file (url, bytes and sha256 still describe it) and saves it converted.
    def converted(model)
      return if model['url'].blank? || !agent_converts?

      stand_in(model, self.class.converted_name(model['filename']), 'convert' => CONVERT)
    end

    def stand_in(model, filename, attrs)
      model.except('fp16_url', 'fp16_bytes', 'fp16_sha256')
           .merge(attrs).merge('filename' => filename, 'replaces' => model['filename'])
    end

    def agent_converts?
      version = @backend.agent_version.to_s.strip
      version.present? && Gem::Version.correct?(version) && Gem::Version.new(version) >= CONVERTING_AGENT
    end
  end
end

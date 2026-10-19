# frozen_string_literal: true

module Agent
  # Apple Silicon runs ComfyUI on PyTorch's MPS device, which can't hold fp8 tensors, so there an fp8 model is
  # swapped for an fp16 one: a copy already on the server, else the official fp16 file when its link exists
  # (EnrichWorkflowModelsJob looks), else the fp8 file, converted by the agent as it downloads. Jobs sent to
  # the server name the stand-ins instead. fp16 weights are twice fp8's size in memory too, so the swap only
  # happens when they fit comfortably in the Mac's memory; otherwise the style stays blocked there.
  class MacWeights # rubocop:disable Metrics/ClassLength
    FP8 = /fp8/i
    FP8_TOKEN = /fp8(?:_e4m3fn|_e5m2)?(?:_scaled)?(?:_fast)?/i
    CONVERT = 'fp8_to_fp16'
    # The first agent that understands `convert` on model.download.
    CONVERTING_AGENT = Gem::Version.new('0.4.13')
    # The share of a Mac's memory a style's fp16 models may take, leaving room for activations, the VAE decode and
    # macOS. Wan 2.2 14B (about 69 GB in fp16) fits a 128 GB Mac, not a 96 GB one.
    MEMORY_SHARE = 0.6

    # Disk a download needs: converting keeps the fp8 file beside its fp16 output (about twice its size) until done.
    def self.disk_bytes(bytes, convert) = bytes.to_i * (convert.present? ? 3 : 1)

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
    def models(models) = swap?(models) ? models.map { substitute(it) || it } : models

    # The fp16 stand-in for an fp8 model, or nil when the model isn't fp8 or has none here.
    def substitute(model)
      return unless active? && self.class.convertible?(model['filename'])

      on_server(model) || official(model) || converted(model)
    end

    # Why a workflow's fp8 models can't run here: per model, or all of them in fp16 needing too much memory.
    def problems(models)
      return [] unless active?

      per_model = models.filter_map { problem(it) }
      return per_model if per_model.any? || models.none? { substitute(it) } || fits?(models)

      [memory_reason(models)]
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
    # fp8 weight_dtype is reset on every Mac, even when the fp16 swap doesn't fit: a style whose files are fp16
    # can still ask ComfyUI to load them as fp8.
    def rewrite(graph, models)
      return graph unless active? && graph.is_a?(Hash)

      renames = swap?(models) ? renames(models) : {}
      graph.transform_values { rewrite_node(it, renames) }
    end

    private

    def renames(models)
      models.each_with_object({}) do |model, map|
        swapped = substitute(model)
        map[model['filename']] = swapped['filename'] if swapped
      end
    end

    def swap?(models) = active? && fits?(models)

    def fits?(models)
      ram = @backend.ram_total
      ram.nil? || memory_bytes(models) <= ram * MEMORY_SHARE
    end

    # fp16 takes twice an fp8 file's size; the official fp16 file's own size is used when known.
    def memory_bytes(models)
      models.sum do |model|
        next model['bytes'].to_i unless substitute(model)

        model['fp16_bytes'].presence&.to_i || (2 * model['bytes'].to_i)
      end
    end

    def memory_reason(models)
      need = ActiveSupport::NumberHelper.number_to_human_size(memory_bytes(models), precision: 2)
      have = ActiveSupport::NumberHelper.number_to_human_size(@backend.ram_total, precision: 2)
      "This style's fp8 models need about #{need} of memory as fp16 (Apple Silicon can't run fp8), and " \
        "#{@backend.name} has #{have}, too little to run them"
    end

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
      return if model['url'].blank? || !@backend.agent_at_least?(CONVERTING_AGENT)

      stand_in(model, self.class.converted_name(model['filename']), 'convert' => CONVERT)
    end

    def stand_in(model, filename, attrs)
      model.except('fp16_url', 'fp16_bytes', 'fp16_sha256')
           .merge(attrs).merge('filename' => filename, 'replaces' => model['filename'])
    end
  end
end

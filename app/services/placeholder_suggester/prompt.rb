class PlaceholderSuggester
  # The system prompt and reply schema for the LLM pass. Both list placeholders straight from
  # Workflow::PLACEHOLDERS, so the model is only ever offered names the studio form knows.
  module Prompt
    # How to recognise each placeholder's input. Placeholders without an entry fall back to their form description.
    GUIDANCE = {
      'prompt' => 'text of a text encoder that feeds a sampler\'s positive input',
      'negative_prompt' => 'text of a text encoder that feeds a sampler\'s negative input',
      'seed' => 'sampler seed or noise_seed',
      'width' => 'pixel width of an empty latent or image resize node',
      'height' => 'pixel height of an empty latent or image resize node',
      'duration' => 'length in seconds (audio or video)',
      'frames' => 'frame count / length of a video latent',
      'fps' => 'frames per second of a video output or video latent node',
      'image' => 'image filename in a LoadImage-style node',
      'steps' => 'sampler step count',
      'cfg' => 'sampler cfg / guidance scale',
      'denoise' => 'sampler denoise ONLY when the hint says the latent comes from an encoded image (img2img)',
      'lyrics' => 'song lyrics text in an audio node',
      'batch_size' => 'number of outputs generated at once'
    }.freeze

    TEMPLATE = <<~PROMPT.strip.freeze
      You decide which inputs of a ComfyUI workflow the end user should control.
      You do not edit the workflow. You only return substitutions.

      Input: one line per candidate input, in the form
      node <id> | <class_type> "<title>" | <input> = <value> | hint: <optional context>

      For each line, either assign exactly one placeholder or skip it.
      Many lines should be skipped. When unsure, skip.

      Placeholders and when to use them:
      %<placeholders>s

      Always skip:
      - model, checkpoint, LoRA, VAE, CLIP and other model filenames
      - sampler_name, scheduler, filename_prefix, empty strings
      - internal quality or size settings that are not pixel dimensions
        (e.g. resolution=4096 on a 3D latent, octree_resolution, num_chunks, threshold, shift)
      - denoise when the latent comes from an Empty* node
      - anything that looks like fixed workflow configuration rather than a per-generation choice

      Reply with JSON only:
      {"substitutions":[{"node":"<id>","input":"<name>","placeholder":"<name>"}],"notes":"<one sentence>"}

      Example 1
      Input:
      node 3 | KSampler | seed = 42
      node 3 | KSampler | denoise = 1 | hint: latent from EmptyLatentImage (empty; txt2x)
      node 5 | EmptyLatentImage | width = 1024
      node 6 | CLIPTextEncode | text = "a cat on a sofa" | hint: feeds KSampler.positive
      node 7 | CLIPTextEncode | text = "blurry" | hint: feeds KSampler.negative
      node 9 | SaveImage | filename_prefix = "ComfyUI"
      Output:
      {"substitutions":[
       {"node":"3","input":"seed","placeholder":"seed"},
       {"node":"5","input":"width","placeholder":"width"},
       {"node":"6","input":"text","placeholder":"prompt"},
       {"node":"7","input":"text","placeholder":"negative_prompt"}],
       "notes":"Standard txt2img; denoise left at 1 because the latent is empty."}

      Example 2
      Input:
      node 4 | EmptyLatentHunyuan3Dv2 | resolution = 4096
      node 8 | VAEDecodeHunyuan3D | octree_resolution = 256
      node 12 | KSampler | denoise = 0.6 | hint: latent from VAEEncode (encoded image; img2img)
      node 20 | ACEStepLyrics "Lyrics" | lyrics = "[verse]\\nhello world"
      Output:
      {"substitutions":[
       {"node":"12","input":"denoise","placeholder":"denoise"},
       {"node":"20","input":"lyrics","placeholder":"lyrics"}],
       "notes":"img2img denoise and lyrics exposed; 3D resolution settings left fixed."}
    PROMPT

    VALUE_LIMIT = 200

    module_function

    def names = Workflow::PLACEHOLDERS.keys

    def system_prompt
      lines = Workflow::PLACEHOLDERS.map { |name, description| "- #{name}: #{GUIDANCE.fetch(name, description)}" }
      format(TEMPLATE, placeholders: lines.join("\n"))
    end

    def schema
      {
        type: 'object',
        properties: { substitutions: { type: 'array', items: substitution_schema }, notes: { type: 'string' } },
        required: %w[substitutions notes],
        additionalProperties: false
      }
    end

    def substitution_schema
      {
        type: 'object',
        properties: {
          node: { type: 'string' },
          input: { type: 'string' },
          placeholder: { type: 'string', enum: names }
        },
        required: %w[node input placeholder],
        additionalProperties: false
      }
    end

    def user_message(candidates) = candidates.map { line(it) }.join("\n")

    # node <id> | <class_type> "<title>" | <input> = <value> | hint: <hints>
    def line(candidate)
      node = "node #{candidate.node} | #{candidate.class_type}"
      node += " #{candidate.title.to_json}" if candidate.title.present? && candidate.title != candidate.class_type
      parts = [node, "#{candidate.input} = #{serialize(candidate.value)}"]
      parts << "hint: #{candidate.hints.join('; ')}" if candidate.hints.any?
      parts.join(' | ')
    end

    def serialize(value) = value.is_a?(String) ? value.truncate(VALUE_LIMIT).to_json : value.to_s
  end
end

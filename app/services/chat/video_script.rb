module Chat
  # Turns a video idea and the studio's specs into the message "Write a script" sends to the chat model.
  # The reply replaces the Video page's description. The template is admin-editable under Settings → Chat;
  # {{name}} tokens are filled from #values.
  class VideoScript
    TOKENS = %w[prompt duration width height aspect_ratio orientation].freeze

    DEFAULT_TEMPLATE = <<~PROMPT.strip.freeze
      You write prompts for an AI video generator.

      Turn the idea below into a script for a video that is {{duration}} seconds long, {{width}}×{{height}} pixels ({{aspect_ratio}}, {{orientation}}).

      The idea:
      {{prompt}}

      Write the script as the prompt itself:
      - Describe what happens in order, with rough timings, so the action fits {{duration}} seconds. Clips this short usually work best as one continuous shot; cut only if the idea needs it.
      - Cover the camera framing and movement, the subjects and what they do, the setting, and the lighting and mood. Compose for the {{orientation}} frame.
      - Describe only what can be seen. No dialogue, narration or on-screen text unless the idea asks for it.
      - Plain prose, under 200 words. No title, headings, lists, markdown, or notes before or after.

      Reply with the script only.
    PROMPT

    attr_reader :prompt, :duration, :width, :height, :aspect_ratio

    def self.default_template = DEFAULT_TEMPLATE

    # Models often wrap a reply in a code fence or label it despite being asked not to.
    def self.clean(reply)
      text = reply.to_s.strip
      text = text.sub(/\A```\w*\n/, '').delete_suffix("\n```").strip
      text.sub(/\A(?:\*\*)?(?:script|prompt):(?:\*\*)?\s*/i, '').strip
    end

    def initialize(prompt:, workflow:, aspect_ratio: nil, duration: nil)
      @prompt = prompt.to_s.strip
      @aspect_ratio = Generation::ASPECT_RATIOS.include?(aspect_ratio) ? aspect_ratio : '16:9'
      @width, @height = Generation.dimensions_for(@aspect_ratio, workflow.base_resolution)
      seconds = duration.presence || GenerationKind.find(:video).default_duration
      @duration = seconds.to_i.clamp(Generation::DURATION_RANGE)
    end

    def orientation
      return 'square' if width == height

      width > height ? 'landscape' : 'portrait'
    end

    def values = TOKENS.index_with { public_send(it).to_s }

    def message(template = AppSetting.current.video_script_prompt_or_default)
      template.gsub(/\{\{\s*(\w+)\s*\}\}/) { values.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
    end
  end
end

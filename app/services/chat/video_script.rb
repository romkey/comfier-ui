module Chat
  # Turns a video idea and the studio's specs into the first message of a script-writing chat.
  # The template is admin-editable under Settings → Chat; {{name}} tokens are filled from #values.
  class VideoScript
    TOKENS = %w[prompt duration width height aspect_ratio orientation].freeze

    DEFAULT_TEMPLATE = <<~PROMPT.strip.freeze
      You are a screenwriter and cinematographer helping plan a short AI-generated video.

      Write a script for a video that is {{duration}} seconds long, {{width}}×{{height}} pixels ({{aspect_ratio}}, {{orientation}}).

      The idea:
      {{prompt}}

      Guidelines:
      - Fit everything into {{duration}} seconds. Clips this short usually work best as one continuous shot; use more only if the idea needs it.
      - For each shot give its timing, framing and camera movement, the subject and what it does, the setting, and the lighting and mood.
      - Compose for the {{orientation}} frame.
      - Describe only what can be seen. No dialogue, narration or on-screen text unless the idea asks for it.

      Finish with a single paragraph of under 120 words, headed "Prompt:", that describes the whole video and can be pasted straight into the video generator.
    PROMPT

    attr_reader :prompt, :duration, :width, :height, :aspect_ratio

    def self.default_template = DEFAULT_TEMPLATE

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

    def title = "Video script: #{prompt}".truncate(60)
  end
end

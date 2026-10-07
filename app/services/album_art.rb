# Cover art for an audio result: fills the admin-editable template (Settings → Album art) from the track's prompt
# and lyrics, and queues it on the chosen image style. {{name}} tokens are replaced; a {{#lyrics}}…{{/lyrics}}
# section is kept only when the track has lyrics.
class AlbumArt
  TOKENS = %w[prompt lyrics].freeze
  SECTION = %r{\{\{\s*#\s*(\w+)\s*\}\}(.*?)\{\{\s*/\s*\1\s*\}\}}m
  TOKEN = /\{\{\s*(\w+)\s*\}\}/
  # Image models only read so much; the opening of a song carries its mood well enough.
  LYRICS_LIMIT = 600

  DEFAULT_TEMPLATE = <<~PROMPT.strip.freeze
    Album cover art for a song described as: {{prompt}}.
    {{#lyrics}}
    Draw on the imagery and mood of its lyrics: {{lyrics}}
    {{/lyrics}}
    Square composition, striking and evocative, rich color and lighting, highly detailed artwork. No text, letters, words, logos or typography.
  PROMPT

  attr_reader :audio

  def self.default_template = DEFAULT_TEMPLATE

  # The style picked under Settings, or the first enabled image style that works from a prompt alone.
  def self.workflow
    chosen = AppSetting.current.album_art_workflow
    return chosen if usable_workflow?(chosen)

    Workflow.enabled.where(kind: 'image').ordered.find { usable_workflow?(it) }
  end

  def self.usable_workflow?(workflow)
    workflow&.enabled? && workflow.image? && workflow.uses?(:prompt) && !workflow.uses?(:image)
  end

  def self.available_for?(generation)
    generation.audio? && generation.succeeded? && workflow.present?
  end

  def initialize(audio)
    @audio = audio
  end

  def values
    { 'prompt' => audio.prompt.to_s.strip.sub(/[.\s]+\z/, ''), 'lyrics' => lyrics }
  end

  def prompt(template = AppSetting.current.album_art_prompt_or_default)
    text = template.gsub(SECTION) { values[Regexp.last_match(1)].present? ? Regexp.last_match(2) : '' }
    text.gsub(TOKEN) { values.fetch(Regexp.last_match(1), Regexp.last_match(0)) }
        .gsub(/\n{3,}/, "\n\n").strip
  end

  # Queues the cover on the album art style and points the track at it, replacing any earlier cover.
  def create!(user:)
    art = user.generations.new(workflow: self.class.workflow, prompt: prompt, aspect_ratio: '1:1')
    Generation.transaction do
      art.save!
      audio.album_art_generation = art
      audio.save!(validate: false) # the track's own fields aren't changing; don't re-check them against its style
    end
    SubmitGenerationJob.perform_later(art)
    art
  end

  private

  # Section markers like [verse] and blank lines mean nothing to an image model.
  def lyrics
    audio.lyrics.to_s.lines.map(&:strip).reject { it.empty? || it.match?(/\A\[[^\]]*\]\z/) }
         .join(' / ').truncate(LYRICS_LIMIT, separator: ' ')
  end
end

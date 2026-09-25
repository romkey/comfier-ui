# Parses workflow JSON that may contain bare {{placeholders}} in numeric slots.
class WorkflowGraphJson
  BARE_PLACEHOLDER = /\A\{\{\s*(\w+)\s*\}\}/

  def self.normalize(text) = new(text).normalize

  def initialize(text)
    @text = text.to_s
  end

  def normalize # rubocop:disable Metrics/MethodLength -- small scanner; splitting would obscure the state machine
    out = +''
    i = 0
    in_string = false
    escaped = false

    while i < @text.length
      if in_string
        char = @text[i]
        out << char
        escaped, in_string = next_string_state(char, escaped, in_string)
        i += 1
      elsif (match = @text[i..].match(BARE_PLACEHOLDER))
        out << '"' << match[0] << '"'
        i += match[0].length
      else
        char = @text[i]
        out << char
        in_string = true if char == '"'
        i += 1
      end
    end

    out
  end

  private

  def next_string_state(char, escaped, in_string)
    return [false, in_string] if escaped
    return [true, in_string] if char == '\\'
    return [false, false] if char == '"'

    [false, in_string]
  end
end

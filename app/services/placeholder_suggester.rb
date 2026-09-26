# Asks LiteLLM to rewrite a ComfyUI API workflow with {{placeholders}} and reports what changed.
class PlaceholderSuggester # rubocop:disable Metrics/ClassLength
  Change = Data.define(:node_id, :node_label, :input, :from, :to, :placeholder) do
    def placeholder_substitution? = placeholder
  end

  Debug = Data.define(:model, :endpoint, :system_prompt, :user_message, :raw_reply)

  class Error < StandardError
    attr_reader :debug

    def initialize(message, debug: nil)
      @debug = debug
      super(message)
    end
  end

  Result = Data.define(:graph, :notes, :changes, :debug)

  WHOLE_PLACEHOLDER = /\A\{\{\s*(\w+)\s*\}\}\z/

  def self.call(graph) = new(graph).call

  def initialize(graph)
    @original = graph.deep_dup
  end

  def call
    debug = build_debug
    raw_reply = fetch_reply(debug)
    debug = debug.with(raw_reply: raw_reply)
    payload = parse_reply(raw_reply, debug)
    graph = payload.fetch('workflow')
    @notes = payload['notes'].to_s.strip
    validate!(graph, debug)
    Result.new(graph:, notes: @notes, changes: diff(@original, graph), debug:)
  end

  private

  def build_debug
    system = AppSetting.current.placeholder_prompt_or_default
    Debug.new(
      model: LiteLlm::Client.model,
      endpoint: "#{LiteLlm::Client.url}/v1/chat/completions",
      system_prompt: system,
      user_message: user_message,
      raw_reply: nil
    )
  end

  def fetch_reply(debug)
    LiteLlm::Client.chat(system: debug.system_prompt, user: debug.user_message)
  rescue LiteLlm::Error => e
    raise Error.new(e.message, debug:)
  end

  def user_message
    placeholders = Workflow::PLACEHOLDERS.map { |name, description| "- {{#{name}}}: #{description}" }.join("\n")
    <<~MESSAGE
      Allowed placeholders:
      #{placeholders}

      Workflow JSON:
      #{JSON.pretty_generate(@original)}
    MESSAGE
  end

  def parse_reply(text, debug)
    json = extract_json(text)
    raise Error.new('The model reply must include a "workflow" object', debug: debug.with(raw_reply: text)) unless
      json['workflow'].is_a?(Hash)

    json
  rescue JSON::ParserError => e
    raise Error.new("The model reply wasn't valid JSON: #{e.message.truncate(200)}", debug: debug.with(raw_reply: text))
  end

  def extract_json(text)
    stripped = text.to_s.strip
    stripped = Regexp.last_match(1) if stripped =~ /\A```(?:json)?\s*(.*?)```\z/m
    JSON.parse(stripped)
  end

  def validate!(graph, debug)
    unless WorkflowModels.api_format?(graph)
      raise Error.new('The suggested workflow must stay in ComfyUI API format', debug:)
    end
    unless graph.keys.sort == @original.keys.sort
      raise Error.new('The suggested workflow must keep the same node IDs', debug:)
    end

    graph.each do |node_id, node|
      original = @original.fetch(node_id)
      if node['class_type'] != original['class_type']
        raise Error.new("Node #{node_id} changed class_type from #{original['class_type']} to #{node['class_type']}",
                        debug:)
      end
    end

    unknown = unknown_placeholders(graph)
    return if unknown.empty?

    raise Error.new("The suggested workflow uses unknown placeholders: #{unknown.sort.join(', ')}", debug:)
  end

  def unknown_placeholders(node, found = Set.new)
    case node
    when Hash then node.each_value { unknown_placeholders(it, found) }
    when Array then node.each { unknown_placeholders(it, found) }
    when String
      node.scan(Workflow::PLACEHOLDER) do |(name)|
        found << name unless Workflow::PLACEHOLDERS.key?(name)
      end
    end
    found
  end

  def diff(before, after)
    before.flat_map do |node_id, node|
      next [] unless node['inputs'].is_a?(Hash)

      node['inputs'].filter_map do |input, old_value|
        new_value = after.dig(node_id, 'inputs', input)
        next if old_value == new_value

        Change.new(
          node_id:,
          node_label: node_label(node),
          input:,
          from: old_value,
          to: new_value,
          placeholder: placeholder_substitution?(old_value, new_value)
        )
      end
    end
  end

  def node_label(node)
    node.dig('_meta', 'title').presence || node['class_type']
  end

  def placeholder_substitution?(from, to)
    return false unless to.is_a?(String) && (match = to.match(WHOLE_PLACEHOLDER))

    Workflow::PLACEHOLDERS.key?(match[1]) && from != to
  end
end

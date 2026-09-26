# Asks LiteLLM to rewrite a ComfyUI API workflow with {{placeholders}} and reports what changed.
class PlaceholderSuggester
  Change = Data.define(:node_id, :node_label, :input, :from, :to, :placeholder) do
    def placeholder_substitution? = placeholder
  end

  class Error < StandardError; end

  Result = Data.define(:graph, :notes, :changes)

  WHOLE_PLACEHOLDER = /\A\{\{\s*(\w+)\s*\}\}\z/

  def self.call(graph) = new(graph).call

  def initialize(graph)
    @original = graph.deep_dup
  end

  def call
    graph = request_suggestion
    validate!(graph)
    Result.new(graph:, notes: @notes, changes: diff(@original, graph))
  end

  private

  def request_suggestion
    reply = LiteLlm::Client.chat(system: AppSetting.current.placeholder_prompt_or_default, user: user_message)
    payload = parse_reply(reply)
    @notes = payload['notes'].to_s.strip
    payload.fetch('workflow')
  rescue LiteLlm::Error => e
    raise Error, e.message
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

  def parse_reply(text)
    json = extract_json(text)
    raise Error, 'The model reply must include a "workflow" object' unless json['workflow'].is_a?(Hash)

    json
  rescue JSON::ParserError => e
    raise Error, "The model reply wasn't valid JSON: #{e.message.truncate(200)}"
  end

  def extract_json(text)
    stripped = text.to_s.strip
    stripped = Regexp.last_match(1) if stripped =~ /\A```(?:json)?\s*(.*?)```\z/m
    JSON.parse(stripped)
  end

  def validate!(graph)
    raise Error, 'The suggested workflow must stay in ComfyUI API format' unless WorkflowModels.api_format?(graph)
    raise Error, 'The suggested workflow must keep the same node IDs' unless graph.keys.sort == @original.keys.sort

    graph.each do |node_id, node|
      original = @original.fetch(node_id)
      raise Error, "Node #{node_id} changed class_type from #{original['class_type']} to #{node['class_type']}" if
        node['class_type'] != original['class_type']
    end

    unknown = unknown_placeholders(graph)
    raise Error, "The suggested workflow uses unknown placeholders: #{unknown.sort.join(', ')}" if unknown.any?
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

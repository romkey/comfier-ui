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
  METADATA_KEYS = %w[notes note summary message explanation].freeze

  def self.call(graph) = new(graph).call

  def initialize(graph)
    @original = normalize_graph(graph)
  end

  def call
    debug = build_debug
    raw_reply = fetch_reply(debug)
    debug = debug.with(raw_reply: raw_reply)
    payload = parse_reply(raw_reply, debug)
    graph = normalize_graph(payload.fetch('workflow'))
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
    workflow, notes = extract_workflow_payload(json)
    unless workflow.is_a?(Hash) && workflow.any?
      raise Error.new('The model reply must include a ComfyUI API-format workflow object',
                      debug: debug.with(raw_reply: text))
    end

    { 'workflow' => workflow, 'notes' => notes.to_s.strip }
  rescue JSON::ParserError => e
    raise Error.new("The model reply wasn't valid JSON: #{e.message.truncate(200)}", debug: debug.with(raw_reply: text))
  end

  def extract_workflow_payload(json)
    json = unwrap_payload(json)
    return [nil, nil] unless json.is_a?(Hash)

    notes = metadata_value(json)
    workflow = [decode_workflow(json['workflow']), workflow_nodes(json)].compact.find do |candidate|
      candidate.is_a?(Hash) && WorkflowModels.api_format?(candidate)
    end
    [workflow, notes]
  end

  def unwrap_payload(json)
    case json
    when Array
      json.find { it.is_a?(Hash) }
    else
      json
    end
  end

  def metadata_value(json)
    METADATA_KEYS.lazy.map { |key| json[key] }.find(&:present?)
  end

  def decode_workflow(value)
    case value
    when Hash
      nodes = workflow_nodes(value)
      nodes if nodes.is_a?(Hash) && WorkflowModels.api_format?(nodes)
    when String
      decode_workflow(JSON.parse(value.strip))
    end
  rescue JSON::ParserError
    nil
  end

  def workflow_nodes(json)
    return json if json.is_a?(Hash) && json.values.all? { workflow_node?(it) }

    return unless json.is_a?(Hash)

    json.reject { |key, _| METADATA_KEYS.include?(key.to_s) }
        .select { |_, value| workflow_node?(value) }
  end

  def workflow_node?(value)
    value.is_a?(Hash) && value['class_type'].is_a?(String) && value['inputs'].is_a?(Hash)
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
      inputs = node['inputs']
      next [] unless inputs.is_a?(Hash)

      inputs.filter_map do |input, old_value|
        new_value = input_value(node_after(after, node_id), input)
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

  def node_after(graph, node_id)
    graph[node_id] || graph[node_id.to_s]
  end

  def input_value(node, input_name)
    inputs = node.is_a?(Hash) ? node['inputs'] : nil
    inputs.is_a?(Hash) ? inputs[input_name] : nil
  end

  def node_label(node)
    meta = node.is_a?(Hash) ? node['_meta'] : nil
    title = meta.is_a?(Hash) ? meta['title'] : nil
    title.presence || node['class_type']
  end

  def normalize_graph(graph)
    return {} unless graph.is_a?(Hash)

    graph.transform_keys(&:to_s).transform_values { normalize_node(it) }
  end

  def normalize_node(node)
    return node unless node.is_a?(Hash)

    node.transform_values { normalize_value(it) }
  end

  def normalize_value(value)
    case value
    when Hash then normalize_node(value)
    when Array then value.map { normalize_value(it) }
    else value
    end
  end

  def placeholder_substitution?(from, to)
    return false unless to.is_a?(String) && (match = to.match(WHOLE_PLACEHOLDER))

    Workflow::PLACEHOLDERS.key?(match[1]) && from != to
  end
end

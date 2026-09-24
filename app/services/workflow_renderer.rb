# Fills a workflow graph's {{placeholders}} with a generation's values.
#
# A string that is exactly one placeholder becomes the raw value, so "{{seed}}" turns into
# the integer 1234 that ComfyUI expects. Placeholders embedded in longer strings are interpolated.
class WorkflowRenderer
  class MissingValue < StandardError; end

  WHOLE_PLACEHOLDER = /\A#{Workflow::PLACEHOLDER}\z/

  def self.render(graph, values) = new(values).render(graph)

  def initialize(values)
    @values = values.stringify_keys
  end

  def render(node)
    case node
    when Hash then node.transform_values { render(it) }
    when Array then node.map { render(it) }
    when WHOLE_PLACEHOLDER then value_for(Regexp.last_match(1))
    when String then node.gsub(Workflow::PLACEHOLDER) { value_for(Regexp.last_match(1)).to_s }
    else node
    end
  end

  private

  def value_for(name)
    @values.fetch(name) { raise MissingValue, "The workflow needs a value for {{#{name}}}" }
  end
end

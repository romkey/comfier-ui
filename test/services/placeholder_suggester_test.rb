require 'test_helper'

class PlaceholderSuggesterTest < ActiveSupport::TestCase
  ORIGINAL = {
    '6' => { 'class_type' => 'CLIPTextEncode', '_meta' => { 'title' => 'Positive' },
             'inputs' => { 'text' => 'a cat on a mat', 'clip' => ['4', 1] } },
    '7' => { 'class_type' => 'CLIPTextEncode', 'inputs' => { 'text' => 'blurry', 'clip' => ['4', 1] } },
    '5' => { 'class_type' => 'EmptyLatentImage', 'inputs' => { 'width' => 512, 'height' => 768, 'batch_size' => 1 } }
  }.freeze

  setup do
    @previous_url = ENV.fetch('LITELLM_URL', nil)
    @previous_model = ENV.fetch('LITELLM_MODEL', nil)
    ENV['LITELLM_URL'] = 'http://litellm.test'
    ENV['LITELLM_MODEL'] = 'gpt-test'
  end

  teardown do
    ENV['LITELLM_URL'] = @previous_url
    ENV['LITELLM_MODEL'] = @previous_model
  end

  test 'returns the suggested graph, notes and a diff of placeholder substitutions' do
    suggested = ORIGINAL.deep_dup
    suggested['6']['inputs']['text'] = '{{prompt}}'
    suggested['7']['inputs']['text'] = '{{negative_prompt}}'
    suggested['5']['inputs']['width'] = '{{width}}'
    stub_completion(workflow: suggested, notes: 'Replaced prompt and size inputs.')

    result = PlaceholderSuggester.call(ORIGINAL)

    assert_equal '{{prompt}}', result.graph.dig('6', 'inputs', 'text')
    assert_equal 'Replaced prompt and size inputs.', result.notes
    assert_equal 3, result.changes.size
    assert result.changes.all?(&:placeholder_substitution?)
    prompt_change = result.changes.find { it.input == 'text' && it.node_id == '6' }

    assert_equal 'Positive', prompt_change.node_label
    assert_equal '{{prompt}}', prompt_change.to
    assert_predicate prompt_change, :placeholder_substitution?
  end

  test 'includes LiteLLM debug metadata in the result' do
    stub_completion(workflow: ORIGINAL, notes: '')

    result = PlaceholderSuggester.call(ORIGINAL)

    assert_includes result.debug.user_message, 'Allowed placeholders:'
    assert_includes result.debug.raw_reply, '"workflow"'
    assert_equal 'gpt-test', result.debug.model
  end

  test 'rejects replies that change node ids' do
    suggested = { '99' => ORIGINAL['6'] }
    stub_completion(workflow: suggested, notes: '')

    error = assert_raises(PlaceholderSuggester::Error) { PlaceholderSuggester.call(ORIGINAL) }

    assert_match(/same node IDs/, error.message)
    assert_includes error.debug.raw_reply, '"workflow"'
  end

  test 'rejects unknown placeholders' do
    suggested = ORIGINAL.deep_dup
    suggested['6']['inputs']['text'] = '{{mystery}}'
    stub_completion(workflow: suggested, notes: '')

    error = assert_raises(PlaceholderSuggester::Error) { PlaceholderSuggester.call(ORIGINAL) }

    assert_match(/unknown placeholders: mystery/, error.message)
  end

  test 'does not crash when the model returns a non-hash _meta or inputs on a node' do
    suggested = ORIGINAL.deep_dup
    suggested['6']['inputs']['text'] = '{{prompt}}'
    suggested['6']['_meta'] = ['broken']
    suggested['7'] = suggested['7'].merge('inputs' => [])
    stub_completion(workflow: suggested, notes: 'Broken metadata.')

    error = assert_raises(PlaceholderSuggester::Error) { PlaceholderSuggester.call(ORIGINAL) }

    assert_match(/API format/, error.message)
    assert_includes error.debug.raw_reply, '"workflow"'
  end

  test 'flags changes that are not exact placeholder substitutions' do
    suggested = ORIGINAL.deep_dup
    suggested['6']['inputs']['text'] = 'prefix {{prompt}}'
    stub_completion(workflow: suggested, notes: '')

    result = PlaceholderSuggester.call(ORIGINAL)

    assert_not result.changes.sole.placeholder_substitution?
  end

  private

  def stub_completion(workflow:, notes:)
    payload = { workflow:, notes: }.to_json
    stub_request(:post, 'http://litellm.test/v1/chat/completions')
      .to_return(body: { choices: [{ message: { content: payload } }] }.to_json)
  end
end

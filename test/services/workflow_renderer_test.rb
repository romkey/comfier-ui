require 'test_helper'

class WorkflowRendererTest < ActiveSupport::TestCase
  test 'whole-value placeholders keep the value type' do
    graph = { '3' => { 'inputs' => { 'seed' => '{{seed}}', 'width' => '{{ width }}' } } }

    rendered = WorkflowRenderer.render(graph, seed: 42, width: 768)

    assert_equal({ '3' => { 'inputs' => { 'seed' => 42, 'width' => 768 } } }, rendered)
  end

  test 'embedded placeholders are interpolated' do
    graph = { '1' => { 'inputs' => { 'text' => 'masterpiece, {{prompt}}, {{seed}}' } } }

    assert_equal 'masterpiece, a fox, 7',
                 WorkflowRenderer.render(graph, prompt: 'a fox', seed: 7).dig('1', 'inputs', 'text')
  end

  test 'leaves links, numbers and plain strings alone' do
    graph = { '1' => { 'class_type' => 'KSampler', 'inputs' => { 'model' => ['4', 0], 'steps' => 20, 'cfg' => 7.5 } } }

    assert_equal graph, WorkflowRenderer.render(graph, {})
  end

  test 'does not modify the original graph' do
    graph = { '1' => { 'inputs' => { 'text' => '{{prompt}}' } } }
    WorkflowRenderer.render(graph, prompt: 'x')

    assert_equal '{{prompt}}', graph.dig('1', 'inputs', 'text')
  end

  test 'raises when a placeholder has no value' do
    error = assert_raises(WorkflowRenderer::MissingValue) do
      WorkflowRenderer.render({ '1' => { 'inputs' => { 'image' => '{{image}}' } } }, prompt: 'x')
    end
    assert_match(/\{\{image\}\}/, error.message)
  end

  test 'renders the fixture workflow for a real generation' do
    generation = users(:alice).generations.create!(workflow: workflows(:sd_image), prompt: 'a fox', seed: '5')

    rendered = WorkflowRenderer.render(workflows(:sd_image).graph, generation.placeholder_values)

    assert_equal 5, rendered.dig('3', 'inputs', 'seed')
    assert_equal 'a fox', rendered.dig('6', 'inputs', 'text')
    assert_equal 512, rendered.dig('5', 'inputs', 'width')
  end
end

require 'test_helper'

module Comfyui
  class ResultTest < ActiveSupport::TestCase
    test 'a missing entry is pending' do
      result = Result.new(nil)

      assert_predicate result, :pending?
      assert_not result.success?
      assert_empty result.files
    end

    test 'collects saved files from every output node and kind' do
      result = Result.new(
        'status' => { 'status_str' => 'success', 'completed' => true },
        'outputs' => {
          '9' => { 'images' => [{ 'filename' => 'a.png', 'subfolder' => '', 'type' => 'output' }] },
          '12' => { 'gifs' => [{ 'filename' => 'b.mp4', 'type' => 'output' }], 'animated' => [true] },
          '15' => { 'audio' => [{ 'filename' => 'c.flac', 'type' => 'output' }] },
          '20' => { 'images' => [{ 'filename' => 'preview.png', 'type' => 'temp' }] }
        }
      )

      assert_predicate result, :success?
      assert_equal %w[a.png b.mp4 c.flac], result.files.pluck('filename')
      assert_equal %w[a.png b.mp4 c.flac preview.png], result.all_files.pluck('filename')
    end

    test 'reports the node and exception for execution errors' do
      result = Result.new(
        'status' => {
          'status_str' => 'error',
          'messages' => [
            ['execution_start', { 'prompt_id' => 'x' }],
            ['execution_error', { 'node_type' => 'KSampler', 'exception_message' => 'CUDA out of memory' }]
          ]
        },
        'outputs' => {}
      )

      assert_predicate result, :error?
      assert_equal 'KSampler: CUDA out of memory', result.error_message
    end

    test 'has a generic error message when ComfyUI gives no details' do
      assert_equal 'ComfyUI reported an error', Result.new('status' => { 'status_str' => 'error' }).error_message
    end

    test 'treats entries without a status (older ComfyUI) as finished' do
      assert_predicate Result.new('outputs' => {}), :success?
    end

    test 'run_seconds comes from execution_start and execution_success timestamps' do
      result = Result.new(
        'status' => {
          'status_str' => 'success',
          'messages' => [
            ['execution_start', { 'timestamp' => 1_000_000 }],
            ['execution_success', { 'timestamp' => 1_028_500 }]
          ]
        },
        'outputs' => {}
      )

      assert_in_delta 28.5, result.run_seconds, 0.01
      assert_in_delta Time.zone.at(1000), result.processing_started_at, 0.001
      assert_in_delta Time.zone.at(1028.5), result.processing_ended_at, 0.001
    end

    test 'processing_ended_at falls back to execution_error' do
      result = Result.new(
        'status' => {
          'status_str' => 'error',
          'messages' => [
            ['execution_start', { 'timestamp' => 2_000_000 }],
            ['execution_error', { 'timestamp' => 2_001_000, 'node_type' => 'KSampler', 'exception_message' => 'OOM' }]
          ]
        },
        'outputs' => {}
      )

      assert_in_delta Time.zone.at(2000), result.processing_started_at, 0.001
      assert_in_delta Time.zone.at(2001), result.processing_ended_at, 0.001
      assert_in_delta 1.0, result.run_seconds, 0.01
    end
  end
end

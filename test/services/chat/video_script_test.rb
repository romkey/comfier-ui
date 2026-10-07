require 'test_helper'

module Chat
  class VideoScriptTest < ActiveSupport::TestCase
    setup do
      @workflow = workflows(:wan_video)
    end

    test 'fills the default template with the prompt and specs' do
      script = VideoScript.new(prompt: '  a fox in the snow ', workflow: @workflow, aspect_ratio: '9:16', duration: '8')
      message = script.message

      assert_includes message, 'a fox in the snow'
      assert_includes message, '8 seconds long'
      assert_includes message, "#{script.width}×#{script.height} pixels (9:16, portrait)"
      assert_equal Generation.dimensions_for('9:16', 640), [script.width, script.height]
      assert_no_match(/\{\{/, message)
    end

    test 'uses the admin template and leaves unknown tokens alone' do
      app_settings(:default).update!(video_script_prompt: 'Script {{ prompt }} for {{duration}}s, {{mood}}')
      script = VideoScript.new(prompt: 'waves', workflow: @workflow, duration: 3)

      assert_equal 'Script waves for 3s, {{mood}}', script.message
    end

    test 'falls back to sensible specs when the form omits them' do
      script = VideoScript.new(prompt: 'waves', workflow: @workflow, aspect_ratio: 'bogus', duration: '999')

      assert_equal '16:9', script.aspect_ratio
      assert_equal 'landscape', script.orientation
      assert_equal Generation::DURATION_RANGE.max, script.duration
      assert_equal GenerationKind.find(:video).default_duration,
                   VideoScript.new(prompt: 'x', workflow: @workflow).duration
    end
  end
end

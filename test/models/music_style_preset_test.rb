require 'test_helper'

class MusicStylePresetTest < ActiveSupport::TestCase
  test 'validates and normalizes personal presets' do
    preset = users(:alice).music_style_presets.create!(name: ' Folk ', description: ' Guitar ')

    assert_equal 'Folk', preset.name
    assert_equal 'Guitar', preset.description
    assert_not users(:alice).music_style_presets.new(name: 'Folk', description: 'Other').valid?
    assert_predicate users(:bob).music_style_presets.new(name: 'Folk', description: 'Other'), :valid?
    assert_not users(:alice).music_style_presets.new(name: ' ', description: ' ').valid?
    assert_not users(:alice).music_style_presets.new(name: 'x' * 101, description: 'x' * 5001).valid?
  end
end

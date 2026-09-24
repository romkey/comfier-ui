require 'test_helper'

class GenerationKindTest < ActiveSupport::TestCase
  test 'has the four studio kinds in nav order' do
    assert_equal ['Image', 'Video', 'Audio', '3D Model'], GenerationKind.all.map(&:label)
  end

  test 'nouns read naturally mid-sentence' do
    assert_equal ['image', 'video', 'audio', '3D model'], GenerationKind.all.map(&:noun)
  end

  test 'every kind has a studio route' do
    GenerationKind::ALL.each do |kind|
      assert_equal kind.path, Rails.application.routes.url_helpers.public_send(:"#{kind.key}_studio_path")
    end
  end

  test 'find raises for unknown kinds' do
    assert_raises(KeyError) { GenerationKind.find('hologram') }
  end
end

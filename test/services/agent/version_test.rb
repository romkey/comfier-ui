# frozen_string_literal: true

require 'test_helper'

module Agent
  class VersionTest < ActiveSupport::TestCase
    test 'expected reads the version of the agent shipped in this repo' do
      source = Rails.root.join('comfyui/comfier_agent/comfier_agent/__init__.py').read

      assert_match(/^\d+\.\d+\.\d+/, Version.expected)
      assert_includes source, %(__version__ = "#{Version.expected}")
    end

    test 'compare says whether the reported version is current, older or newer' do
      assert_equal :current, Version.compare('0.2.0', expected: '0.2.0')
      assert_equal :outdated, Version.compare('0.1.0', expected: '0.2.0')
      assert_equal :outdated, Version.compare('0.2.0', expected: '0.10.0')
      assert_equal :newer, Version.compare('0.3.0', expected: '0.2.0')
    end

    test 'compare is unknown when either side is missing or unparseable' do
      assert_equal :unknown, Version.compare(nil, expected: '0.2.0')
      assert_equal :unknown, Version.compare('', expected: '0.2.0')
      assert_equal :unknown, Version.compare('not a version!', expected: '0.2.0')
      assert_equal :unknown, Version.compare('0.2.0', expected: nil)
    end
  end
end

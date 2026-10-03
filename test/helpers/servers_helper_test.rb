# frozen_string_literal: true

require 'test_helper'

class ServersHelperTest < ActionView::TestCase
  include ServersHelper

  test 'needs_downloads shows how many models are already on the server' do
    record = WorkflowAvailability.new(status: 'needs_downloads',
                                      details: { 'models' => [{}, {}], 'required_model_count' => 5,
                                                 'total_bytes' => 2.gigabytes })
    html = availability_cell(record)

    assert_includes html, '3 of 5 downloaded'
  end
end

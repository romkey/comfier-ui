# frozen_string_literal: true

require 'test_helper'

class StudioServerPinTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
    @workflow = workflows(:sd_image)
    @ready = create_agent_backend!(owner: @user, name: 'Ready box', visibility: 'public')
    bring_online_for!(@ready, @workflow)
    Agent::Availability.recompute_for_backend!(@ready)

    @missing = create_agent_backend!(owner: @user, name: 'Empty box', visibility: 'public')
    bring_online!(@missing, node_types: inventory_for(@workflow)[:node_types])
    Agent::Availability.recompute_for_backend!(@missing)
  end

  test 'lists every runnable server and disables ones without models installed' do
    pin = StudioServerPin.new(@workflow, @user)
    choices = pin.choices
    ready = choices.find { it.backend.id == @ready.id }
    missing = choices.find { it.backend.id == @missing.id }

    assert ready
    assert missing

    assert_predicate ready, :selectable
    assert_includes ready.label, 'Ready box'
    assert_not_predicate missing, :selectable
    assert_includes missing.label, 'Empty box'
    assert_includes missing.label, 'models not installed yet'
    assert_equal({ disabled: 'disabled' }, missing.html_options)
  end

  test 'shows the picker when the only server cannot run the workflow' do
    Backend.where.not(id: @missing.id).find_each(&:destroy!)
    pin = StudioServerPin.new(@workflow, @user)

    assert_predicate pin.show_picker?, :present?
    assert_not_predicate pin.choices.first, :selectable
  end

  test 'pinnable? follows model readiness' do
    pin = StudioServerPin.new(@workflow, @user)

    assert pin.pinnable?(@ready)
    assert_not pin.pinnable?(@missing)
  end
end

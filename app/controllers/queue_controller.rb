# The job queue: everything waiting on or running on ComfyUI, with time estimates.
class QueueController < ApplicationController
  def index
    @estimate = QueueEstimator.call
    @show_backend = current_user.admin? || Backend.enabled.many?
  end
end

class ReportsController < ApplicationController
  include ReportSubmission

  def create
    generation = Generation.shared.find(params[:id])
    return head :not_found if generation.user_id == current_user.id

    submit_report(generation, source: :member, reporter_id: current_user.id, return_to: shared_path(generation))
  end
end

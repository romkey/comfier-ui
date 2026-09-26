class PublicReportsController < ApplicationController
  include ReportSubmission

  allow_unauthenticated_access
  skip_privacy_gate

  def create
    generation = Generation.succeeded.where(hidden_for_review_at: nil).find_by!(public_token: params[:token])
    submit_report(generation, source: :public, return_to: public_share_path(params[:token]))
  end
end

module Admin
  class ReportsController < BaseController
    before_action :set_case, only: %i[show update unshare revoke_public_link destroy_generation]

    def index
      scope = ReportCase.includes(:owner, :generation).recent
      @status = params[:status].presence || 'open'
      scope = case @status
              when 'open' then scope.open_cases
              when 'reviewed' then scope.where(status: :reviewed)
              else scope
              end
      @open_count = ReportCase.open_cases.count
      @pagy, @report_cases = pagy(:offset, scope, limit: 50)
    end

    def show
      @reports = @report_case.reports.includes(:reporter).order(created_at: :desc)
      @generation = @report_case.generation&.then do |gen|
        Generation.with_attached_outputs.find_by(id: gen.id)
      end
    end

    def update
      permitted = params.expect(report_case: %i[conclusion review_note delete_generation])
      conclusion = permitted[:conclusion].presence_in(ReportCase.conclusions.keys)
      unless conclusion
        return redirect_to admin_report_path(@report_case), alert: 'Choose a conclusion.',
                                                            status: :see_other
      end

      save_review!(permitted, conclusion)
      redirect_to admin_report_path(@report_case), notice: 'Review saved.', status: :see_other
    end

    def unshare
      return head :not_found unless @generation

      @generation.unshare!
      notify_owner(@generation.user, @generation.title, :unshared, @report_case.latest_report&.category_label)
      redirect_to admin_report_path(@report_case), notice: 'Stopped sharing with members.', status: :see_other
    end

    def revoke_public_link
      return head :not_found unless @generation&.publicly_linked?

      @generation.revoke_public_link!
      notify_owner(@generation.user, @generation.title, :link_revoked, @report_case.latest_report&.category_label)
      redirect_to admin_report_path(@report_case), notice: 'Public link revoked.', status: :see_other
    end

    def destroy_generation
      return head :not_found unless @generation

      title = @generation.title
      owner = @generation.user
      category = @report_case.latest_report&.category_label
      @generation.destroy!
      notify_owner(owner, title, :deleted, category)
      redirect_to admin_reports_path, notice: 'Result deleted.', status: :see_other
    end

    private

    def set_case
      @report_case = ReportCase.find(params[:id])
      @generation = @report_case.generation
    end

    def save_review!(permitted, conclusion)
      delete_generation = ActiveModel::Type::Boolean.new.cast(permitted[:delete_generation])
      title = @report_case.display_title
      owner = @report_case.owner
      category = @report_case.latest_report&.category_label

      @report_case.review!(
        reviewer: current_user,
        conclusion:,
        review_note: permitted[:review_note],
        delete_generation:
      )

      return unless conclusion == 'removed' && owner

      action = delete_generation ? :deleted : :removed
      notify_owner(owner, title, action, category)
    end

    def notify_owner(user, title, action, category)
      NotifyOwnerOfModerationJob.perform_later(user, title:, action:, category:)
    end
  end
end

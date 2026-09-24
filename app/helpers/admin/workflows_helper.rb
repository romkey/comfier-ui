module Admin
  module WorkflowsHelper
    # Installed is the norm, so it's just a dot; anything else says what's going on.
    def model_status_cell(backend, requirement, download)
      status = backend.model_status(requirement)
      return downloading_label if download&.active?
      return tag.span(class: 'status-dot status-success', title: "Installed on #{backend.name}") if status == :installed
      if download&.failed?
        return tag.span('Download failed', class: 'badge text-bg-danger-subtle', title: download.error_message)
      end
      return tag.span('Missing', class: 'badge text-bg-warning-subtle') if status == :missing

      tag.span('—', class: 'text-secondary', title: 'Not checked yet')
    end

    def download_method(backend)
      if backend.downloader_available? then 'Comfier downloader node'
      elsif backend.manager_version.present? then "ComfyUI-Manager #{backend.manager_version} (catalog models only)"
      end
    end

    ModelProblem = Data.define(:backend, :title, :message, :paths)

    # Files that are missing and won't install by clicking Install: failed downloads with their reason, and
    # files the backend has no way to fetch. Files sharing a backend and a reason are grouped.
    def model_problems(workflow, backends, downloads)
      found = backends.flat_map do |backend|
        backend.missing_models(workflow).filter_map do |requirement|
          model_problem_row(backend, requirement, downloads[[backend.id, requirement.directory, requirement.name]])
        end
      end
      found.group_by { it.first(3) }.map do |(backend, title, message), rows|
        ModelProblem.new(backend:, title:, message:, paths: rows.map(&:last))
      end
    end

    def delete_workflow_button(workflow, used: nil)
      used = Generation.where(workflow_id: workflow.id).count if used.nil?
      confirm = "Remove #{workflow.name}?"
      confirm += " #{used} past #{'result'.pluralize(used)} will stay." if used.positive?
      button_to 'Delete', admin_workflow_path(workflow), method: :delete, class: 'dropdown-item text-danger',
                                                         form: { data: { turbo_confirm: confirm, turbo: false } }
    end

    private

    def model_problem_row(backend, requirement, download)
      return if download&.active?

      route = backend.download_route(requirement)
      if download&.failed?
        retry_hint = route ? ' Fix that, then choose Install to try again.' : ''
        [backend, 'Download failed', "#{download.error_message}#{retry_hint}", requirement.path]
      elsif route.nil?
        [backend, "Can't download", backend.download_blocker, requirement.path]
      end
    end

    def downloading_label
      tag.span(class: 'text-12 text-secondary text-nowrap') do
        safe_join([tag.span(class: 'spinner-border spinner-border-sm me-1', aria: { hidden: true }), 'Downloading'])
      end
    end
  end
end

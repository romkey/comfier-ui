module Admin
  module BackendsHelper
    def backend_status_dot(backend)
      state = if backend.enabled? && backend.unhealthy? then 'danger'
              elsif backend.enabled? && backend.last_check_ok then 'success'
              else 'muted'
              end
      tag.span(class: "status-dot status-#{state}", title: backend_status_text(backend))
    end

    # Healthy and enabled is the norm, so it gets no label; everything else says what's wrong.
    def backend_status_label(backend)
      return tag.span('Disabled', class: 'badge text-bg-secondary-subtle') unless backend.enabled?
      if backend.unhealthy?
        return tag.span('Unreachable', class: 'badge text-bg-danger-subtle', title: backend.last_check_message)
      end
      return tag.span('Not checked yet', class: 'badge text-bg-warning-subtle') if backend.last_checked_at.nil?

      tag.span(backend.last_check_message, class: 'text-secondary')
    end

    private

    def backend_status_text(backend)
      return 'Disabled' unless backend.enabled?
      return "Unreachable: #{backend.last_check_message}" if backend.unhealthy?

      backend.last_check_message || 'Not checked yet'
    end
  end
end

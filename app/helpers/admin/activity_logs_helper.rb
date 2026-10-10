module Admin
  module ActivityLogsHelper
    KIND_BADGE_VARIANTS = {
      'login' => 'text-bg-success-subtle',
      'login_failed' => 'text-bg-danger-subtle',
      'logout' => 'text-bg-secondary-subtle',
      'generation_succeeded' => 'text-bg-success-subtle',
      'generation_failed' => 'text-bg-danger-subtle',
      'generation_cancelled' => 'text-bg-warning-subtle',
      'llm_chat' => 'text-bg-primary-subtle',
      'media_failed' => 'text-bg-danger-subtle'
    }.freeze

    KIND_LABELS = {
      'login' => 'Sign in',
      'login_failed' => 'Sign-in failed',
      'logout' => 'Sign out',
      'generation_queued' => 'Generation queued',
      'generation_succeeded' => 'Generation succeeded',
      'generation_failed' => 'Generation failed',
      'generation_cancelled' => 'Generation cancelled',
      'llm_chat' => 'LLM request',
      'media_failed' => "Video didn't play"
    }.freeze

    def activity_log_kind_label(kind)
      KIND_LABELS.fetch(kind.to_s, kind.to_s.humanize)
    end

    def activity_log_kind_filter_path(kind)
      params = request.query_parameters.symbolize_keys.except(:page)
      params[:kind] = kind
      admin_activity_logs_path(params)
    end

    def activity_log_kind_badge(log)
      classes = activity_log_kind_badge_classes(log.kind)
      tag.span(activity_log_kind_label(log.kind), class: classes)
    end

    def activity_log_kind_badge_classes(kind)
      variant = KIND_BADGE_VARIANTS.fetch(kind.to_s, 'text-bg-secondary-subtle')
      "badge text-11 #{variant}"
    end

    def activity_log_details_json(log)
      JSON.pretty_generate(log.details.as_json)
    rescue StandardError
      log.details.to_s
    end
  end
end

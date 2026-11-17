module Metrics
  module Sections
    # The activity log is append-only, so its counts only grow: use rate() and increase() on these to see
    # generations started, failed and cancelled, sign-ins, failed sign-ins, chat calls and so on over time.
    class Activity < Base
      def collect
        counter('comfier_activity_events_total', 'Events in the activity log, by kind.',
                by(:kind, ActivityLog.group(:kind).count, ActivityLog.kinds.keys))
      end
    end
  end
end

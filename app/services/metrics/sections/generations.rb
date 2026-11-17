module Metrics
  module Sections
    # Generations as they stand in the database. These are gauges: deleting a result lowers them. For rates
    # that survive deletion, use comfier_activity_events_total.
    class Generations < Base
      STATUSES = %w[queued running succeeded failed cancelled].freeze
      # A cancelled agent job is stored as failed; report it as its own status.
      STATUS_SQL = "CASE WHEN agent_state = 'cancelled' THEN 'cancelled' ELSE status END".freeze
      STATE_SQL = 'COALESCE(agent_state, status)'.freeze

      def collect
        totals
        by_workflow
        in_progress
        attempts
        sharing
      end

      private

      def totals
        counts = Generation.group(:kind, Arel.sql(STATUS_SQL)).count
        samples = GenerationKind.keys.product(STATUSES).map do |kind, status|
          [{ kind:, status: }, counts.fetch([kind, status], 0)]
        end
        gauge('comfier_generations', 'Generations in the database, by kind and status.', samples)
        gauge('comfier_generations_via_api', 'Generations in the database that were started through the API.',
              ApiGenerationRequest.where.not(generation_id: nil).count)
      end

      def by_workflow
        counts = Generation.group(:workflow_name, :kind, Arel.sql(STATUS_SQL)).count
        gauge('comfier_workflow_generations', 'Generations in the database, by workflow, kind and status.',
              counts.map { |(workflow, kind, status), count| [{ workflow: workflow.to_s, kind:, status: }, count] })
      end

      def in_progress
        counts = Generation.in_progress.group(:kind, Arel.sql(STATE_SQL)).count
        gauge('comfier_generations_in_progress',
              'Generations waiting or running now, by kind and detailed state (routing, waiting_models, running, …).',
              counts.map { |(kind, state), count| [{ kind:, state: }, count] })
        oldest = Generation.queued.minimum(:created_at)
        gauge('comfier_generations_oldest_queued_seconds', 'Age of the oldest generation still queued; 0 when none.',
              oldest ? (Time.current - oldest).clamp(0, nil) : 0)
        warm = Generation.in_progress.where.not(predicted_end_at: nil).maximum(:predicted_end_at)
        gauge('comfier_queue_predicted_drain_seconds',
              'Seconds until the last waiting or running generation is predicted to finish; 0 when unknown.',
              warm ? (warm - Time.current).clamp(0, nil) : 0)
      end

      # One row per try at running a generation on a server; a generation that was moved has several.
      def attempts
        counts = JobAttempt.left_joins(:backend).group('backends.name', :outcome, :infra).count
        gauge('comfier_job_attempts',
              'Tries at running a generation on a server, by server and outcome. infra="true" means the server ' \
              'or connection was at fault, not the job.',
              counts.map { |(server, outcome, infra), count| [{ server: server.to_s, outcome:, infra: }, count] })
      end

      def sharing
        gauge('comfier_generations_shared', 'Generations shared with other users.',
              Generation.where.not(shared_at: nil).count)
        gauge('comfier_generations_public_links', 'Generations with a public link.',
              Generation.where.not(public_token: nil).count)
        gauge('comfier_generations_hidden_for_review', 'Generations hidden while a report is reviewed.',
              Generation.where.not(hidden_for_review_at: nil).count)
        gauge('comfier_public_link_views', 'Views of public links, summed over the generations that still exist.',
              Generation.sum(:public_view_count))
      end
    end
  end
end

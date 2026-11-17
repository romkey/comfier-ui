require 'sidekiq/api'

module Metrics
  module Sections
    # Sidekiq, which runs the background jobs. Read from Redis.
    class JobQueue < Base
      def collect
        totals(stats)
        queues
      end

      private

      def stats = ::Sidekiq::Stats.new

      def queue_list = ::Sidekiq::Queue.all

      def totals(stats)
        counter('comfier_sidekiq_processed_total', 'Background jobs Sidekiq has run.', stats.processed)
        counter('comfier_sidekiq_failed_total', 'Background jobs that raised an error.', stats.failed)
        gauge('comfier_sidekiq_enqueued', 'Background jobs waiting in all queues.', stats.enqueued)
        gauge('comfier_sidekiq_scheduled', 'Background jobs scheduled for later.', stats.scheduled_size)
        gauge('comfier_sidekiq_retries', 'Background jobs waiting to be retried.', stats.retry_size)
        gauge('comfier_sidekiq_dead', 'Background jobs that ran out of retries.', stats.dead_size)
        gauge('comfier_sidekiq_busy', 'Background jobs running now.', stats.workers_size)
        gauge('comfier_sidekiq_processes', 'Sidekiq processes running.', stats.processes_size)
      end

      def queues
        list = queue_list
        gauge('comfier_sidekiq_queue_size', 'Background jobs waiting in the queue.',
              list.map { [{ queue: it.name }, it.size] })
        gauge('comfier_sidekiq_queue_latency_seconds', 'How long the oldest job in the queue has waited.',
              list.map { [{ queue: it.name }, it.latency] })
      end
    end
  end
end

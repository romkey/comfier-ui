module Metrics
  module Sections
    # How long successful generations took, as histograms by kind, worked out from the rows in the database.
    # Deleting results lowers the counts, which Prometheus treats as a counter reset.
    class Durations < Base
      BUCKETS = [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1200, 1800, 3600].freeze

      # Legacy servers record ComfyUI's own start time; agent servers record when the job began running.
      STARTED = 'COALESCE(processing_started_at, running_at)'.freeze
      HISTOGRAMS = {
        'comfier_generation_run_seconds' => [
          'Time successful generations spent running on a server.',
          "COALESCE(run_seconds, EXTRACT(EPOCH FROM (COALESCE(processing_ended_at, completed_at) - #{STARTED})))"
        ],
        'comfier_generation_queue_wait_seconds' => [
          'Time successful generations waited before they started running.',
          "EXTRACT(EPOCH FROM (#{STARTED} - created_at))"
        ],
        'comfier_generation_total_seconds' => [
          'Time from request to finished result for successful generations.',
          'EXTRACT(EPOCH FROM (completed_at - created_at))'
        ]
      }.freeze

      BUCKET_COLUMNS = BUCKETS.each_with_index.map do |le, index|
        "COUNT(*) FILTER (WHERE seconds <= #{le}) AS b#{index}"
      end.join(', ').freeze

      # Generations missing a timestamp are left out (GREATEST alone would turn their NULL into 0); clock skew that
      # gives a negative time counts as 0.
      QUERIES = HISTOGRAMS.transform_values do |(_help, expression)|
        <<~SQL.squish.freeze
          SELECT kind, COUNT(*) AS n, SUM(seconds) AS total, #{BUCKET_COLUMNS}
          FROM (SELECT kind, GREATEST(#{expression}, 0) AS seconds FROM generations
                WHERE status = 'succeeded' AND (#{expression}) IS NOT NULL) timed
          GROUP BY kind ORDER BY kind
        SQL
      end.freeze

      def collect
        HISTOGRAMS.each { |name, (help, _expression)| histogram(name, help, series(name)) }
      end

      private

      def series(name)
        ApplicationRecord.connection.select_all(QUERIES.fetch(name), 'Metrics durations').map do |row|
          { labels: { kind: row['kind'] }, count: row['n'], sum: row['total'].to_f,
            buckets: BUCKETS.each_with_index.to_h { |le, index| [le, row["b#{index}"]] } }
        end
      end
    end
  end
end

module Metrics
  module Sections
    class Base
      WINDOWS = { '1d' => 1.day, '7d' => 7.days, '30d' => 30.days }.freeze

      def initialize(registry)
        @registry = registry
      end

      private

      attr_reader :registry

      delegate :gauge, :counter, :histogram, to: :registry

      # One sample per window: [{ window: '7d' }, yield(7.days.ago)].
      def windowed
        WINDOWS.map { |label, span| [{ window: label }, yield(span.ago)] }
      end

      # Samples for a grouped count, with a zero for every expected value so series don't come and go.
      def by(label, counts, expected = [])
        counts = counts.transform_keys(&:to_s)
        (expected.map(&:to_s) | counts.keys).map { [{ label => it }, counts.fetch(it, 0)] }
      end
    end
  end
end

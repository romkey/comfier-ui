require 'test_helper'

module Metrics
  class RegistryTest < ActiveSupport::TestCase
    setup { @registry = Registry.new }

    test 'a bare value becomes one sample with help and type' do
      @registry.gauge('things', 'How many things.', 3)

      assert_equal "# HELP things How many things.\n# TYPE things gauge\nthings 3\n", @registry.to_s
    end

    test 'labelled samples share one family' do
      @registry.counter('events_total', 'Events.', [[{ kind: 'a' }, 1], [{ kind: 'b', ok: true }, 2.5]])

      assert_includes @registry.to_s, "# TYPE events_total counter\nevents_total{kind=\"a\"} 1\n"
      assert_includes @registry.to_s, 'events_total{kind="b",ok="true"} 2.5'
    end

    test 'nil values are left out, and a family with no samples is not printed' do
      @registry.gauge('free_bytes', 'Free.', [[{ server: 'a' }, nil], [{ server: 'b' }, 10]])
      @registry.gauge('nothing', 'Nothing.', [])

      assert_not_includes @registry.to_s, 'server="a"'
      assert_includes @registry.to_s, 'free_bytes{server="b"} 10'
      assert_not_includes @registry.to_s, 'nothing'
    end

    test 'label values and help text are escaped' do
      @registry.gauge('info', "Line one\nand a \\ slash", [[{ server: "Bob's \"fast\" box\\\nnew" }, 1]])

      assert_includes @registry.to_s, '# HELP info Line one\\nand a \\\\ slash'
      assert_includes @registry.to_s, 'info{server="Bob\'s \\"fast\\" box\\\\\\nnew"} 1'
    end

    test 'booleans, whole floats and odd floats are written as numbers' do
      @registry.gauge('flags', 'Flags.', [[{ n: 1 }, true], [{ n: 2 }, false], [{ n: 3 }, 4.0],
                                          [{ n: 4 }, Float::NAN], [{ n: 5 }, Float::INFINITY],
                                          [{ n: 6 }, BigDecimal('1.25')]])
      lines = @registry.to_s.lines(chomp: true).last(6).map { it.split.last }

      assert_equal %w[1 0 4 NaN +Inf 1.25], lines
    end

    test 'a histogram writes cumulative buckets, +Inf, sum and count' do
      @registry.histogram('run_seconds', 'Run time.',
                          [{ labels: { kind: 'image' }, buckets: { 1 => 0, 10 => 2 }, sum: 31.5, count: 3 }])

      assert_equal <<~TEXT, @registry.to_s
        # HELP run_seconds Run time.
        # TYPE run_seconds histogram
        run_seconds_bucket{kind="image",le="1"} 0
        run_seconds_bucket{kind="image",le="10"} 2
        run_seconds_bucket{kind="image",le="+Inf"} 3
        run_seconds_sum{kind="image"} 31.5
        run_seconds_count{kind="image"} 3
      TEXT
    end
  end
end

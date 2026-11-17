module Metrics
  # Collects metric families and writes them in the Prometheus text exposition format (0.0.4).
  # Samples are given as [labels, value] pairs; a nil value is left out.
  class Registry
    CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8'.freeze

    Family = Struct.new(:name, :type, :help, :lines)

    def initialize
      @families = {}
    end

    def gauge(name, help, samples) = add(name, 'gauge', help, samples)

    def counter(name, help, samples) = add(name, 'counter', help, samples)

    # `series` is a list of { labels:, buckets: { upper_bound => cumulative count }, sum:, count: }.
    def histogram(name, help, series)
      lines = family(name, 'histogram', help).lines
      series.each do |one|
        labels = one.fetch(:labels, {})
        one.fetch(:buckets).each { |le, count| lines << line("#{name}_bucket", labels.merge(le: number(le)), count) }
        lines << line("#{name}_bucket", labels.merge(le: '+Inf'), one.fetch(:count))
        lines << line("#{name}_sum", labels, one.fetch(:sum))
        lines << line("#{name}_count", labels, one.fetch(:count))
      end
    end

    def to_s
      @families.values.reject { it.lines.empty? }.map do |family|
        ["# HELP #{family.name} #{escape_help(family.help)}", "# TYPE #{family.name} #{family.type}", *family.lines]
          .join("\n")
      end.join("\n").concat("\n")
    end

    private

    def add(name, type, help, samples)
      samples = [[{}, samples]] unless samples.is_a?(Array)
      lines = family(name, type, help).lines
      samples.each { |labels, value| lines << line(name, labels, value) unless value.nil? }
    end

    def family(name, type, help)
      @families[name] ||= Family.new(name, type, help, [])
    end

    def line(name, labels, value)
      rendered = labels.map { |key, val| %(#{key}="#{escape_label(val)}") }.join(',')
      rendered.empty? ? "#{name} #{number(value)}" : "#{name}{#{rendered}} #{number(value)}"
    end

    def number(value)
      case value
      when true then '1'
      when false then '0'
      when Integer then value.to_s
      else float(value.to_f)
      end
    end

    def float(value)
      return 'NaN' if value.nan?
      return value.positive? ? '+Inf' : '-Inf' if value.infinite?

      value == value.to_i ? value.to_i.to_s : value.round(6).to_s
    end

    def escape_label(value) = value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("\n", '\\n')

    def escape_help(value) = value.to_s.gsub('\\', '\\\\\\\\').gsub("\n", '\\n')
  end
end

module Metrics
  # Builds the /metrics page. Everything is read from the database, Redis and Sidekiq when Prometheus asks,
  # so the numbers are the same whichever web process answers and nothing has to be counted as it happens.
  # A section that fails is logged and flagged in comfier_scrape_section_errors; the rest still report.
  class Collector
    SECTIONS = {
      'build' => Sections::Build,
      'users' => Sections::Users,
      'generations' => Sections::Generations,
      'durations' => Sections::Durations,
      'servers' => Sections::Servers,
      'content' => Sections::Content,
      'activity' => Sections::Activity,
      'sidekiq' => Sections::JobQueue
    }.freeze

    def self.render(...) = new(...).render

    def initialize(sections: SECTIONS)
      @sections = sections
    end

    def render
      registry = Registry.new
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      errors = @sections.map { |name, section| [{ section: name }, run(name, section, registry)] }
      registry.gauge('comfier_scrape_section_errors', 'Whether a section of this page failed to collect (1) or not.',
                     errors)
      registry.gauge('comfier_scrape_duration_seconds', 'Time spent collecting this page.',
                     Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      registry.to_s
    end

    private

    def run(name, section, registry)
      section.new(registry).collect
      0
    rescue StandardError => e
      Rails.logger.warn("[metrics] #{name} failed: #{e.class}: #{e.message}")
      1
    end
  end
end

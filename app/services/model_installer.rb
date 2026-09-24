# Queues downloads of missing model files onto a backend.
class ModelInstaller
  Outcome = Data.define(:queued, :unavailable, :already_running)

  def self.queue(backend, requirements) = new(backend).queue(requirements)

  def initialize(backend)
    @backend = backend
  end

  def queue(requirements)
    active = @backend.model_downloads.active.pluck(:directory, :name)
    downloadable, unavailable = requirements.map { with_link(it) }.partition { it.url && @backend.download_route(it) }
    already_running, fresh = downloadable.partition { active.include?(it.key) }

    queued = fresh.map do |requirement|
      @backend.model_downloads.create!(requirement.to_h).tap { StartModelDownloadJob.perform_later(it) }
    end
    Outcome.new(queued:, unavailable:, already_running:)
  end

  private

  # Manager installs from its own catalog, so its link stands in when the workflow doesn't have one.
  def with_link(requirement)
    return requirement if requirement.url || @backend.downloader_available?

    requirement.with_url(@backend.manager_catalog[requirement.path])
  end
end

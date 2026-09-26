# Estimates how long queued and running jobs will take, per job and for the whole queue.
class QueueEstimator
  FALLBACK_SECONDS = { 'image' => 30, 'video' => 180, 'audio' => 60, 'model_3d' => 120 }.freeze
  MIN_REMAINING = 5.seconds

  Estimate = Data.define(:generation, :position, :remaining_seconds, :backend)

  def self.call = new.call

  def initialize(now: Time.current)
    @now = now
  end

  def call
    jobs = Generation.in_progress.includes(:workflow, :backend, :user).order(:created_at, :id).to_a
    return empty if jobs.empty?

    backend_free_at = Hash.new { @now }
    estimates = schedule_jobs(jobs, backend_free_at)
    total_clear = backend_free_at.values.max - @now
    new_job_wait = backend_free_at.values.min - @now
    { jobs: estimates, total_clear_seconds: total_clear.to_i.clamp(0, Float::INFINITY),
      new_job_wait_seconds: new_job_wait.to_i.clamp(0, Float::INFINITY), count: jobs.size }
  end

  def estimate_seconds(generation)
    history = recent_runs(generation)
    work = job_work(generation)
    return FALLBACK_SECONDS.fetch(generation.kind, 60) if history.empty? || work.zero?

    per_unit = history.filter_map { |run| run.processing_seconds&.fdiv([job_work(run), 1].max) }.sort
    (per_unit[per_unit.size / 2] * work).round.clamp(5, 3600)
  end

  private

  def schedule_jobs(jobs, backend_free_at)
    jobs.map.with_index(1) do |job, position|
      backend = job.backend || least_busy_backend(backend_free_at)
      start_at = [backend_free_at[backend], job.submitted_at || job.created_at].compact.max
      remaining = [estimate_seconds(job) - (@now - start_at), MIN_REMAINING].max
      backend_free_at[backend] = start_at + remaining
      Estimate.new(generation: job, position:, remaining_seconds: remaining.to_i, backend:)
    end
  end

  def empty
    { jobs: [], total_clear_seconds: 0, new_job_wait_seconds: 0, count: 0 }
  end

  def least_busy_backend(free_at)
    Backend.enabled.ordered.min_by { |backend| free_at[backend] } || Backend.enabled.first
  end

  def recent_runs(generation)
    return [] unless generation.workflow_id

    Generation.succeeded.where(workflow_id: generation.workflow_id).where.not(processing_started_at: nil)
              .order(completed_at: :desc).limit(20).to_a
  end

  def job_work(generation)
    params = generation.parameters
    frames = [params['frames'].to_i, 1].max
    batch = [params['batch_size'].to_i, 1].max
    frames * batch * steps_factor_for(params['quality'])
  end

  def steps_factor_for(quality)
    { 'fast' => 0.5, 'best' => 1.5 }.fetch(quality, 1.0)
  end
end

require 'test_helper'

class ModelInstallerTest < ActiveJob::TestCase
  setup { @backend = backends(:gpu) }

  test 'queues a download per linked requirement and sorts out the rest' do
    @backend.update!(downloader_available: true)
    running = @backend.model_downloads.create!(directory: 'vae', name: 'ae.safetensors', url: 'https://hf.test/ae',
                                               status: :running)
    requirements = ['checkpoints/sd15.safetensors https://hf.test/sd15', 'loras/nolink.safetensors',
                    'vae/ae.safetensors https://hf.test/ae'].map { ModelRequirement.parse_line(it) }

    outcome = nil
    assert_enqueued_jobs(1, only: StartModelDownloadJob) { outcome = ModelInstaller.queue(@backend, requirements) }

    assert_equal ['sd15.safetensors'], outcome.queued.map(&:name)
    assert_equal ['nolink.safetensors'], outcome.unavailable.map(&:name)
    assert_equal [running.requirement], outcome.already_running
    assert_predicate outcome.queued.first, :queued?
  end

  test 'with only Manager, queues catalog files using the catalog link and skips the rest' do
    @backend.update!(manager_version: '4.2.2',
                     manager_catalog: { 'checkpoints/sd15.safetensors' => 'https://hf.test/sd15' })
    requirements = ['checkpoints/sd15.safetensors', 'checkpoints/custom.safetensors https://hf.test/custom']
                   .map { ModelRequirement.parse_line(it) }

    outcome = ModelInstaller.queue(@backend, requirements)

    assert_equal ['https://hf.test/sd15'], outcome.queued.map(&:url)
    assert_equal ['custom.safetensors'], outcome.unavailable.map(&:name)
  end

  test 'nothing is queued on a backend that cannot download' do
    outcome = nil
    assert_no_enqueued_jobs do
      outcome = ModelInstaller.queue(@backend, [ModelRequirement.parse_line('vae/ae.safetensors https://hf.test/ae')])
    end

    assert_equal 1, outcome.unavailable.size
  end

  test 'finished downloads do not block a new attempt' do
    @backend.update!(downloader_available: true)
    @backend.model_downloads.create!(directory: 'vae', name: 'ae.safetensors', url: 'https://hf.test/ae',
                                     status: :failed)

    outcome = ModelInstaller.queue(@backend, [ModelRequirement.parse_line('vae/ae.safetensors https://hf.test/ae')])

    assert_equal 1, outcome.queued.size
  end
end

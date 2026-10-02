# frozen_string_literal: true

require 'test_helper'

module Agent
  class DownloadsTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @alice = users(:alice)
      @workflow = workflows(:sd_image)
      backends(:gpu).update!(enabled: false)
      set_model_links(@workflow, url: 'https://huggingface.co/x/sd15.safetensors', bytes: 2.gigabytes)
      @backend = create_agent_backend!(owner: @alice)
      @socket = bring_online!(@backend, node_types: inventory_for(@workflow)[:node_types])
    end

    def submit(user: @alice)
      gen = Generation.create!(user:, workflow: @workflow, prompt: 'x', kind: :image, status: :queued,
                               agent_state: 'routing', filled_workflow_json: { '1' => {} })
      availability = Availability.compute(@workflow, @backend)
      gen.agent_transition!(from: 'routing', to: 'waiting_models', backend_id: @backend.id, queued_at: Time.current)
      DownloadPlanner.ensure_downloads!(@backend, availability.models, generation: gen, auto: true)
      gen.reload
    end

    def download = ModelDownload.find_by!(backend: @backend, name: 'v1-5-pruned-emaonly-fp16.safetensors')

    def download_event(type, **fields)
      agent_message(@backend, { 'type' => type, 'download_id' => download.agent_download_id }.merge(fields))
    end

    test 'a job needing a model waits, and runs once the download completes' do
      gen = submit

      assert_equal 'waiting_models', gen.agent_state
      assert_equal 'sent', download.agent_state

      assert_enqueued_jobs(2, only: Turbo::Streams::BroadcastStreamJob) do
        download_event('model.download.progress', state: 'downloading', bytes_done: 1.gigabyte, speed_bps: 50_000_000)
      end

      assert_equal 1.gigabyte, download.bytes_done

      download_event('model.download.completed', sha256: 'c' * 64, bytes: 2.gigabytes)

      assert_equal 'queued', gen.reload.agent_state
      assert BackendModel.exists?(backend: @backend, filename: 'v1-5-pruned-emaonly-fp16.safetensors')
      assert_equal 'completed', download.agent_state
    end

    test 'two jobs needing the same file share one download' do
      first = submit
      second = submit

      assert_equal 1, ModelDownload.where(backend: @backend).count
      assert_equal [first.id, second.id], download.for_generation_ids
      assert_equal 1, @socket.of_type('model.download').size
    end

    test 'one download at a time per server, waiting jobs first' do
      manual = DownloadPlanner.manual!(@backend, [{ 'folder' => 'vae', 'filename' => 'ae.safetensors',
                                                    'url' => 'https://huggingface.co/x/ae' }], user: @alice).first

      assert_equal 'sent', manual.reload.agent_state
      gen = submit

      assert_equal 'queued', download.agent_state
      agent_message(@backend, { 'type' => 'model.download.completed', 'download_id' => manual.agent_download_id })

      assert_equal 'sent', download.agent_state
      assert_equal 'waiting_models', gen.reload.agent_state
    end

    test 'too little disk fails the download without sending it' do
      agent_status(@backend, disk_free: { 'models' => 11.gigabytes })
      set_model_links(@workflow, bytes: 500.megabytes)
      DownloadPlanner.manual!(@backend, [{ 'folder' => 'vae', 'filename' => 'big.safetensors', 'bytes' => 5.gigabytes,
                                           'url' => 'https://huggingface.co/x/big' }], user: @alice)
      big = ModelDownload.find_by!(name: 'big.safetensors')

      assert_equal 'failed', big.agent_state
      assert_equal 'disk_full', big.agent_reason
      assert_empty @socket.of_type('model.download')
    end

    test 'a failed download fails its waiting job with the reason' do
      gen = submit
      download_event('model.download.failed', reason: 'http_error', detail: 'HTTP 401')
      gen.reload

      assert_equal 'failed', gen.agent_state
      assert_equal 'huggingface.co refused the download (HTTP 401). Check the access token for huggingface.co.',
                   gen.error_message
    end

    test 'a failed download moves waiting jobs to a server that has the file' do
      other = create_agent_backend!(owner: @alice, name: 'Other')
      gen = submit
      bring_online_for!(other, @workflow)
      download_event('model.download.failed', reason: 'hash_mismatch')

      assert_equal other.id, gen.reload.backend_id
    end

    test 'a failed download leaves a mine_only job waiting for another own server that is starting' do
      @alice.update!(backend_affinity: 'mine_only')
      starting = create_agent_backend!(owner: @alice, name: 'Starting')
      connect_agent!(starting)
      gen = submit
      download_event('model.download.failed', reason: 'http_error', detail: 'HTTP 500')
      gen.reload

      assert_equal 'routing', gen.agent_state
      assert_equal 'waiting_for_server', gen.agent_phase
    end

    test 'a shutdown during download queues it again' do
      submit
      download_event('model.download.failed', reason: 'cancelled_by_shutdown')

      assert_equal 'queued', download.agent_state
    end

    test 'downloads the agent forgot are resent after a reconnect' do
      submit
      socket = connect_agent!(@backend)
      agent_hello(@backend, active_downloads: [])
      agent_status(@backend)
      Reconciliation.run!(@backend)

      assert_equal download.agent_download_id, socket.last_of_type('model.download')['download_id']
    end

    test 'downloads the frontend does not know are cancelled on hello' do
      socket = connect_agent!(@backend)
      agent_hello(@backend, active_downloads: [{ 'download_id' => 'd_unknown', 'state' => 'downloading' }])

      assert_equal 'd_unknown', socket.last_of_type('model.download.cancel')['download_id']
    end

    test 'cancelling a sent download asks the agent' do
      submit
      DownloadLifecycle.cancel_by_user!(download, user: @alice)

      assert_equal 'cancelling', download.agent_state
      assert @socket.last_of_type('model.download.cancel')
      download_event('model.download.cancelled')

      assert_equal 'cancelled', download.agent_state
    end

    test 'cancelling a waiting job keeps the automatic download going' do
      gen = submit
      JobLifecycle.cancel_by_user!(gen)

      assert_equal 'cancelled', gen.reload.agent_state
      assert_equal 'sent', download.agent_state
      assert_empty download.for_generation_ids
    end

    test 'the owner token for a host goes with downloads from it and its subdomains only' do
      SourceCredential.create!(host: 'huggingface.co', secret: 'hf_owner', owner_user: @alice)
      SourceCredential.create!(host: 'huggingface.co', secret: 'hf_global')
      SourceCredential.create!(host: 'civitai.com', secret: 'civ_global')

      assert_equal({ 'Authorization' => 'Bearer hf_owner' },
                   CredentialHeaders.for_url('https://cdn-lfs.huggingface.co/f', backend: @backend))
      assert_equal({}, CredentialHeaders.for_url('https://huggingface.co.evil.test/f', backend: @backend))
      assert_equal({}, CredentialHeaders.for_url('https://nothuggingface.co/f', backend: @backend))

      bobs = create_agent_backend!(owner: users(:bob), name: 'Bob box')

      assert_equal({ 'Authorization' => 'Bearer hf_global' },
                   CredentialHeaders.for_url('https://huggingface.co/f', backend: bobs))
    end

    test 'the download message carries the token' do
      SourceCredential.create!(host: 'huggingface.co', secret: 'hf_owner', owner_user: @alice)
      submit

      assert_equal 'Bearer hf_owner', @socket.last_of_type('model.download').dig('headers', 'Authorization')
    end

    test 'credentials are encrypted and only the last four are shown' do
      credential = SourceCredential.create!(host: 'https://HuggingFace.co/', secret: 'hf_abcdefgh1234')

      assert_equal 'huggingface.co', credential.host
      assert_equal '1234', credential.last4
      assert_not_includes SourceCredential.connection.select_value(
        "SELECT secret FROM source_credentials WHERE id = #{credential.id}"
      ), 'hf_abcdefgh1234'
    end
  end
end

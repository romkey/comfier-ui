require 'test_helper'

class BackendSelectorTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
    @gpu = backends(:gpu)
  end

  def add_backend(name, url)
    Backend.create!(name:, base_url: url)
  end

  def stub_queue(backend, depth)
    stub_request(:get, comfy_url(backend, 'queue'))
      .to_return(body: { queue_running: [], queue_pending: Array.new(depth) { [it, "p#{it}"] } }.to_json)
  end

  test 'uses the only enabled backend without asking it anything' do
    assert_equal @gpu, BackendSelector.call(@user)
  end

  test 'uses the preferred backend when it is enabled' do
    other = add_backend('Other', 'http://other.test')
    @user.update!(preferred_backend: other)

    assert_equal other, BackendSelector.call(@user)
  end

  test 'ignores a preferred backend that was disabled later' do
    other = add_backend('Other', 'http://other.test')
    @user.update!(preferred_backend: other)
    other.update!(enabled: false)

    assert_equal @gpu, BackendSelector.call(@user.reload)
  end

  test 'picks the least busy backend' do
    other = add_backend('Other', 'http://other.test')
    stub_queue(@gpu, 3)
    stub_queue(other, 1)

    assert_equal other, BackendSelector.call(@user)
  end

  test 'skips unreachable backends' do
    other = add_backend('Other', 'http://other.test')
    stub_queue(@gpu, 10)
    stub_request(:get, comfy_url(other, 'queue')).to_raise(Errno::ECONNREFUSED)

    assert_equal @gpu, BackendSelector.call(@user)
  end

  test 'raises when every backend is unreachable' do
    other = add_backend('Other', 'http://other.test')
    stub_request(:get, comfy_url(@gpu, 'queue')).to_timeout
    stub_request(:get, comfy_url(other, 'queue')).to_timeout

    assert_raises(BackendSelector::NoBackendAvailable) { BackendSelector.call(@user) }
  end

  test 'skips backends known to be missing the workflow’s models, even if preferred' do
    other = add_backend('Other', 'http://other.test')
    @gpu.update!(model_inventory: { 'checkpoints' => [] })
    @user.update!(preferred_backend: @gpu)

    assert_equal other, BackendSelector.call(@user, workflows(:sd_image))
  end

  test 'backends that have not been checked yet still get jobs' do
    assert_equal @gpu, BackendSelector.call(@user, workflows(:sd_image))
  end

  test 'says which style lacks models when no backend has them' do
    @gpu.update!(model_inventory: { 'checkpoints' => ['other.safetensors'] })

    error = assert_raises(BackendSelector::NoBackendAvailable) { BackendSelector.call(@user, workflows(:sd_image)) }
    assert_match(/models the SD 1.5 style needs/, error.message)
  end

  test 'raises when no backend is enabled' do
    @gpu.update!(enabled: false)

    assert_raises(BackendSelector::NoBackendAvailable) { BackendSelector.call(@user) }
  end
end

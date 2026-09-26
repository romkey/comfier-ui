# A stand-in for ComfyUI's HTTP API so the app can be exercised end to end without a GPU.
# Every prompt "finishes" a few seconds after submission with a generated PNG.
# It also has a small model inventory and the Comfier downloader node, whose downloads
# "finish" the same way, so model installs can be tried out too.
#
#   docker compose -f docker-compose.dev.yml --profile fake up fake-comfyui
#   then add a backend with URL http://fake-comfyui:8188
require 'json'
require 'securerandom'
require 'zlib'

class FakeComfyui # rubocop:disable Metrics/ClassLength
  RENDER_SECONDS = 3
  DOWNLOADER = 'ComfierModelDownload'.freeze
  FOLDERS = %w[checkpoints diffusion_models text_encoders vae loras controlnet clip_vision upscale_models].freeze

  def initialize
    @prompts = {}
    @models = Hash.new { |models, folder| models[folder] = [] }
    @models['checkpoints'] << 'v1-5-pruned-emaonly-fp16.safetensors'
    @deleted_history = []
    @mutex = Mutex.new
  end

  def call(env)
    request = Rack::Request.new(env)
    (request.post? ? post(request) : get(request)) || [404, {}, ['not found']]
  end

  private

  def get(request)
    case request.path_info
    when '/system_stats' then json(system: { comfyui_version: 'fake' }, devices: [{ name: 'Fake GPU' }])
    when '/queue' then json(queue_running: [], queue_pending: pending.map { [0, it] })
    when %r{\A/history/(.+)\z} then history(Regexp.last_match(1))
    when '/view' then [200, { 'content-type' => 'image/png' }, [png(request.params['filename'].to_s.hash)]]
    when %r{\A/models(?:/(\w+))?\z} then models(Regexp.last_match(1))
    when "/object_info/#{DOWNLOADER}" then json(DOWNLOADER => { name: DOWNLOADER, output_node: true })
    end
  end

  def post(request)
    body = JSON.parse(request.body.read.presence || '{}')
    case request.path_info
    when '/prompt' then submit(body['prompt'])
    when '/upload/image' then json(name: 'upload.png', subfolder: '', type: 'input')
    when '/comfier/cleanup' then cleanup(body)
    when '/history' then delete_history(body)
    when '/queue' then cancel_queue(body)
    when '/interrupt' then cancel_interrupt(body)
    end
  end

  def submit(graph)
    id = SecureRandom.uuid
    download = graph.values.find { it['class_type'] == DOWNLOADER }&.dig('inputs')
    @mutex.synchronize { @prompts[id] = { at: now, download: } }
    json(prompt_id: id, number: @prompts.size, node_errors: {})
  end

  def history(id)
    prompt = @mutex.synchronize { @prompts[id] }
    return json({}) if prompt.nil? || (!prompt[:cancelled] && now - prompt[:at] < RENDER_SECONDS)
    return json(id => cancelled_entry) if prompt[:cancelled]
    return json(id => finish_download(prompt[:download])) if prompt[:download]

    image = { filename: "fake_#{id[0, 8]}.png", subfolder: '', type: 'output' }
    json(id => success_entry(image))
  end

  def success_entry(image)
    finish = (Time.now.to_f * 1000).to_i
    start = finish - (RENDER_SECONDS * 1000)
    {
      status: {
        status_str: 'success', completed: true,
        messages: [['execution_start', { 'timestamp' => start }], ['execution_success', { 'timestamp' => finish }]]
      },
      outputs: { '9' => { images: [image] } }
    }
  end

  def finish_download(inputs)
    folder = inputs['directory']
    return { status: { status_str: 'error', completed: false, messages: [] } } unless FOLDERS.include?(folder)

    @mutex.synchronize { @models[folder] |= [inputs['filename']] }
    { status: { status_str: 'success', completed: true },
      outputs: { '1' => { text: ["Downloaded #{inputs['filename']}"] } } }
  end

  # The folder list, or the files in one folder.
  def models(folder)
    return json(FOLDERS) if folder.nil?
    return [404, {}, ['not found']] unless FOLDERS.include?(folder)

    json(@mutex.synchronize { @models[folder].dup })
  end

  def cleanup(body)
    deleted = Array(body['files']).filter_map { |file| file['filename'] if file.is_a?(Hash) }
    deleted << body['input_image'] if body['input_image'].present?
    @mutex.synchronize { @deleted_history << body['prompt_id'] if body['prompt_id'].present? }
    json(deleted:, skipped: [])
  end

  def delete_history(body)
    @mutex.synchronize { Array(body['delete']).each { |id| @deleted_history << id } }
    [200, {}, ['']]
  end

  def cancel_queue(body)
    Array(body['delete']).each { |id| mark_cancelled(id) }
    [200, {}, ['']]
  end

  def cancel_interrupt(body)
    mark_cancelled(body['prompt_id']) if body['prompt_id'].present?
    [200, {}, ['']]
  end

  def mark_cancelled(id)
    @mutex.synchronize { @prompts[id]&.merge!(cancelled: true) }
  end

  def cancelled_entry
    { status: { status_str: 'error', completed: true,
                messages: [['execution_error', { node_type: 'Comfier', exception_message: 'Interrupted' }]] } }
  end

  def pending
    @mutex.synchronize do
      @prompts.reject { |_, prompt| prompt[:cancelled] }.select { |_, prompt| now - prompt[:at] < RENDER_SECONDS }.keys
    end
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def json(body) = [200, { 'content-type' => 'application/json' }, [body.to_json]]

  # A square gradient whose colours depend on the seed-ish value passed in.
  def png(seed, size = 256)
    header = [size, size, 8, 2, 0, 0, 0].pack('N2C5')
    "\x89PNG\r\n\x1a\n".b + png_chunk('IHDR', header) +
      png_chunk('IDAT', Zlib::Deflate.deflate(pixel_rows(seed, size))) + png_chunk('IEND', '')
  end

  def pixel_rows(seed, size)
    r = seed & 0xff
    g = (seed >> 8) & 0xff
    b = (seed >> 16) & 0xff
    Array.new(size) do |y|
      "\x00".b + Array.new(size) { |x| [(r + x) % 256, (g + y) % 256, (b + x + y) % 256].pack('C3') }.join
    end.join
  end

  def png_chunk(type, data) = [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
end

run FakeComfyui.new

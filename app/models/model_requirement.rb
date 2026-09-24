# A model file a workflow needs: the ComfyUI models folder it lives in (checkpoints, vae, ...),
# its name inside that folder, and optionally a direct link to download it from.
class ModelRequirement
  DIRECTORY = /\A[a-z0-9_]+\z/i
  # Hugging Face's /blob/ links are the web page about a file; /resolve/ is the file itself.
  HUGGING_FACE_PAGE = %r{\A(https?://(?:www\.)?huggingface\.co/(?:(?:datasets|spaces)/)?[^/]+/[^/]+)/blob/}i

  attr_reader :directory, :name, :url

  def initialize(directory:, name:, url: nil)
    @directory = directory.to_s.strip
    @name = name.to_s.strip.tr('\\', '/')
    @url = url.to_s.strip.sub(HUGGING_FACE_PAGE, '\1/resolve/').presence
  end

  def self.from_h(hash) = new(directory: hash['directory'], name: hash['name'], url: hash['url'])

  # "vae/wan_2.1_vae.safetensors https://huggingface.co/.../wan_2.1_vae.safetensors"
  def self.parse_line(line)
    path, url, *extra = line.split
    directory, name = path.to_s.split('/', 2)
    new(directory:, name:, url: extra.empty? ? url : [url, *extra].join(' '))
  end

  def key = [directory, name]
  def path = "#{directory}/#{name}"
  def to_line = [path, url].compact.join(' ')
  def to_h = { 'directory' => directory, 'name' => name, 'url' => url }.compact
  def with_url(url) = self.class.new(directory:, name:, url:)

  def ==(other) = other.is_a?(self.class) && to_h == other.to_h
  alias eql? ==
  delegate :hash, to: :to_h

  def problems
    [].tap do |found|
      unless directory.match?(DIRECTORY)
        found << "#{path}: the folder must be a ComfyUI models folder, like checkpoints or vae"
      end
      found << "#{path}: the file name isn't valid" unless valid_name?
      found << "#{path}: the download link must be a single http(s) URL" unless valid_url?
    end
  end

  private

  def valid_name?
    name.present? && !name.start_with?('/') && name.split('/').none? { it.empty? || it == '..' }
  end

  def valid_url?
    return true if url.nil?

    uri = URI.parse(url)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end
end

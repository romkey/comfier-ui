# A ComfyUI server that generations can be sent to. Configured by admins.
class Backend < ApplicationRecord
  encrypts :auth_token

  has_many :generations, dependent: :nullify
  has_many :model_downloads, dependent: :delete_all
  has_many :preferring_users, class_name: 'User', foreign_key: :preferred_backend_id,
                              inverse_of: :preferred_backend, dependent: :nullify

  normalizes :base_url, with: ->(url) { url.strip.chomp('/') }
  normalizes :auth_token, with: ->(token) { token.strip.presence }

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :base_url, presence: true
  validate :base_url_is_http

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:name) }
  scope :unhealthy, -> { where(last_check_ok: false) }

  def client(**) = Comfyui::Client.new(self, **)

  def unhealthy? = last_check_ok == false

  # Pings the server and records the outcome so admins can see which backends are reachable.
  # A reachable server also gets its model inventory and download options refreshed.
  def check!
    stats = client(open_timeout: 3, read_timeout: 10).system_stats
    update!(last_checked_at: Time.current, last_check_ok: true, last_check_message: describe_stats(stats))
    refresh_inventory!
    true
  rescue Comfyui::Error => e
    update!(last_checked_at: Time.current, last_check_ok: false, last_check_message: e.message.truncate(250))
    false
  end

  # Records which files are in the given models folders, and whether models can be downloaded
  # (through the Comfier downloader node or ComfyUI-Manager). Returns false if the server can't be reached.
  def refresh_inventory!(directories = Workflow.model_directories)
    api = client(open_timeout: 3, read_timeout: 20)
    listed = directories.index_with { api.model_files(it) }
    downloader = api.downloader_node?
    manager = api.manager_version
    update!(model_inventory: model_inventory.merge(listed), inventory_checked_at: Time.current,
            downloader_available: downloader, manager_version: manager,
            manager_catalog: downloader || manager.nil? ? {} : fetch_manager_catalog(api))
    true
  rescue Comfyui::Error
    false
  end

  # :installed, :missing, or :unknown when the folder hasn't been checked yet.
  def model_status(requirement)
    files = model_inventory[requirement.directory]
    return :unknown if files.nil?

    files.include?(requirement.name) ? :installed : :missing
  end

  def missing_models(workflow) = workflow.required_models.select { model_status(it) == :missing }

  def can_download_models? = downloader_available? || manager_version.present?

  # How this backend would fetch a file: :node needs a download link, :manager needs an exact catalog entry.
  def download_route(requirement)
    if downloader_available?
      :node if requirement.url
    elsif manager_version.present?
      :manager if manager_catalog.key?(requirement.path)
    end
  end

  def downloadable_models(workflow) = missing_models(workflow).select { download_route(it) }

  # Why download_route is nil, in words an admin can act on.
  def download_blocker
    if downloader_available?
      'No download link. Add one under Models.'
    elsif manager_version.present?
      "Not in ComfyUI-Manager's catalog, which is all Manager can download. " \
        "Install the Comfier downloader node on #{name} to download any file."
    else
      "#{name} can't download models. Install the Comfier downloader node (see the README)."
    end
  end

  private

  # Manager's catalog as "folder/file" => link.
  def fetch_manager_catalog(api)
    api.manager_catalog.each_with_object({}) do |entry, catalog|
      path = Comfyui::ManagerCatalog.path(entry)
      catalog[path] = entry['url'] if path
    end
  rescue Comfyui::Error
    manager_catalog
  end

  def describe_stats(stats)
    version = stats.dig('system', 'comfyui_version')
    device = Array(stats['devices']).first&.fetch('name', nil)
    ['ComfyUI', version, device && "· #{device}"].compact.join(' ')
  end

  def base_url_is_http
    return if base_url.blank?

    uri = URI.parse(base_url)
    errors.add(:base_url, 'must be an http:// or https:// URL') unless uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    errors.add(:base_url, 'is not a valid URL')
  end
end

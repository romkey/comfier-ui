# A ComfyUI server that generations can be sent to. Legacy servers are called over HTTP by the
# frontend; agent servers run the Comfier Agent node and connect to the frontend themselves.
class Backend < ApplicationRecord # rubocop:disable Metrics/ClassLength
  encrypts :auth_token

  CONNECTION_KINDS = %w[legacy agent].freeze
  VISIBILITIES = %w[private shared public].freeze
  AUTO_DOWNLOAD_POLICIES = %w[off owner_jobs all_jobs].freeze

  belongs_to :owner_user, class_name: 'User', optional: true
  has_many :backend_keys, dependent: :delete_all
  has_many :backend_shares, dependent: :delete_all
  has_many :shared_users, through: :backend_shares, source: :user
  has_many :backend_models, dependent: :delete_all
  has_one :backend_inventory, dependent: :delete
  has_many :backend_object_infos, dependent: :delete_all
  has_many :workflow_availabilities, dependent: :delete_all
  has_many :generations, dependent: :nullify
  has_many :model_downloads, dependent: :delete_all
  has_many :job_attempts, dependent: :nullify
  has_one :backend_speed, dependent: :delete
  has_many :perf_stats, dependent: :delete_all
  has_many :transfer_stats, dependent: :delete_all
  has_many :backend_load_minutes, dependent: :delete_all
  has_many :backend_load_hours, dependent: :delete_all
  has_many :preferring_users, class_name: 'User', foreign_key: :preferred_backend_id,
                              inverse_of: :preferred_backend, dependent: :nullify

  normalizes :base_url, with: ->(url) { url.to_s.strip.chomp('/').presence }
  normalizes :auth_token, with: ->(token) { token.strip.presence }

  validates :name, presence: true, uniqueness: { case_sensitive: false }, length: { maximum: 80 }
  validates :description, length: { maximum: 500 }
  validates :connection_kind, inclusion: { in: CONNECTION_KINDS }
  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :auto_download_policy, inclusion: { in: AUTO_DOWNLOAD_POLICIES }
  validates :max_queued_per_other_user, numericality: { only_integer: true, in: 0..1000 }
  validates :base_url, presence: true, if: :legacy?
  validate :base_url_is_http, if: :legacy?

  scope :enabled, -> { where(enabled: true, deleted_at: nil) }
  scope :kept, -> { where(deleted_at: nil) }
  scope :ordered, -> { order(:name) }
  scope :unhealthy, -> { where(last_check_ok: false) }
  scope :agent, -> { where(connection_kind: 'agent') }
  scope :legacy, -> { where(connection_kind: 'legacy') }

  def legacy? = connection_kind == 'legacy'
  def agent? = connection_kind == 'agent'
  def deleted? = deleted_at.present?

  def owned_by?(user) = user.present? && owner_user_id == user.id

  def unhealthy? = legacy? ? last_check_ok == false : !Agent::Presence.online?(self)

  def client(**) = Comfyui::Client.new(self, **)

  # Creates a key and returns the secret, which is never retrievable again.
  def issue_agent_key!
    full, prefix, digest = Agent::KeyService.generate!
    backend_keys.create!(prefix:, key_hash: digest)
    full
  end

  def allows_workflow?(workflow) = !workflow_disabled?(workflow)

  def workflow_disabled?(workflow) = disabled_workflow_ids.include?(workflow.id)

  # Turns one style on or off for this server. Returns true when the setting changed.
  def set_workflow_enabled!(workflow, enabled)
    return false if enabled == allows_workflow?(workflow)

    ids = enabled ? disabled_workflow_ids - [workflow.id] : (disabled_workflow_ids + [workflow.id]).sort
    update!(disabled_workflow_ids: ids)
    true
  end

  def allows_auto_download_for?(user)
    case auto_download_policy
    when 'all_jobs' then true
    when 'owner_jobs' then owned_by?(user)
    else false
    end
  end

  # Custom node class names reported by the agent (inventory message and/or cached object_info).
  def installed_node_types
    names = Array(backend_inventory&.node_types_json).map(&:to_s)
    info = backend_object_infos.first&.data
    names.concat(info.keys.map(&:to_s)) if info.present?
    names.uniq
  end

  # Execution engines the agent reported, e.g. { 'comfyui' => {}, 'mflux' => { 'version' => …, 'models' => [...] } }.
  # Empty while nothing it runs is available (say ComfyUI is down on a ComfyUI-only server). Legacy servers, and
  # agents that haven't sent an inventory yet, run ComfyUI only.
  def engines
    backend_inventory ? backend_inventory.engines_json : { 'comfyui' => {} }
  end

  def runs_engine?(key) = engines.key?(key.to_s)
  def engine_info(key) = engines[key.to_s] || {}
  def engine_models(key) = Array(engine_info(key)['models']).map(&:to_s)

  # Memory the agent reported in its last hello. On Apple Silicon the GPU shares it.
  def ram_total
    bytes = system_json&.dig('ram_total_bytes').to_i
    bytes.positive? ? bytes : nil
  end

  def speed_index = backend_speed&.speed_index || 1.0

  def online? = agent? ? Agent::Presence.online?(self) : last_check_ok != false

  # :current, :outdated, :newer or :unknown, against the agent this build of Comfier ships.
  def agent_version_status = Agent::Version.compare(agent_version)

  # Pings the server and records the outcome so admins can see which backends are reachable.
  # A reachable server also gets its model inventory and download options refreshed.
  def check!
    return Agent::Presence.online?(self) if agent?

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
    return request_agent_inventory! if agent?

    api = client(open_timeout: 3, read_timeout: 20)
    listed = directories.index_with { api.model_files(it) }
    downloader = api.downloader_node?
    manager = api.manager_version
    update!(model_inventory: model_inventory.merge(listed), inventory_checked_at: Time.current,
            downloader_available: downloader, manager_version: manager,
            manager_catalog: downloader || manager.nil? ? {} : fetch_manager_catalog(api))
    sync_routing_inventory!(listed, api)
    true
  rescue Comfyui::Error
    false
  end

  # :installed, :missing, or :unknown when the folder hasn't been checked yet.
  def model_status(requirement)
    return agent_model_status(requirement) if agent?

    files = model_inventory[requirement.directory]
    return :unknown if files.nil?

    files.include?(requirement.name) ? :installed : :missing
  end

  def missing_models(workflow) = workflow.required_models.select { model_status(it) == :missing }

  # Populates backend_inventory from the last HTTP model listing so routing works without a post-upgrade refresh.
  def ensure_routing_inventory!
    return backend_inventory if agent? || backend_inventory.present?
    return if model_inventory.blank?

    hash = Digest::SHA256.hexdigest(JSON.generate(model_inventory))
    Agent::InventoryStore.store!(self, { 'hash' => hash, 'models' => model_inventory, 'node_types' => [] })
    backend_inventory
  end

  def can_download_models? = agent? ? model_downloads_enabled? : downloader_available? || manager_version.present?

  # From the agent hello: 0 means no limit on concurrent downloads. Default 1 when unknown.
  def agent_download_concurrency
    val = system_json.dig('model_download', 'max_concurrent')
    val.nil? ? 1 : val.to_i
  end

  def agent_use_hf_cli?
    system_json.dig('model_download', 'use_hf_cli') != false
  end

  def downloadable_missing_models
    workflows_for_server.flat_map { downloadable_models(it) }.uniq(&:path)
  end

  # mflux and MLX video models this server's styles need, as downloads the engine fetches by name.
  def downloadable_engine_models
    return [] unless agent? && can_download_models?

    engine_workflows = workflows_for_server.where.not(engine: 'comfyui')
    models = engine_workflows.flat_map { Agent::Availability.compute(it, self).models }
    models.uniq { [it['folder'], it['filename']] }
  end

  def workflows_for_server
    scope = Workflow.enabled.ordered
    disabled_workflow_ids.empty? ? scope : scope.where.not(id: disabled_workflow_ids)
  end

  # How this backend would fetch a file: :agent and :node need a download link, :manager needs an
  # exact catalog entry.
  def download_route(requirement)
    return manager_catalog.key?(requirement.path) ? :manager : nil if manager_only?
    return unless requirement.url

    if agent? then :agent if model_downloads_enabled?
    elsif downloader_available? then :node
    end
  end

  def manager_only? = !agent? && !downloader_available? && manager_version.present?

  def downloadable_models(workflow) = missing_models(workflow).select { download_route(it) }

  # Why download_route is nil, in words an admin can act on.
  def download_blocker
    if agent?
      model_downloads_enabled? ? 'No download link. Add one under Models.' : "#{name} doesn't allow model downloads."
    elsif downloader_available?
      'No download link. Add one under Models.'
    elsif manager_version.present?
      "Not in ComfyUI-Manager's catalog, which is all Manager can download. " \
        "Switch #{name} to the Comfier Agent to download any file."
    else
      "#{name} can't download models. Switch it to the Comfier Agent (see the README)."
    end
  end

  def soft_delete!
    transaction do
      backend_keys.active.find_each(&:revoke!)
      update!(deleted_at: Time.current, enabled: false, name: "#{name} (deleted #{id})")
    end
  end

  private

  def agent_model_status(requirement)
    return :unknown unless backend_inventory

    present = Agent::ModelMatcher.new(backend_models.pluck(:folder, :filename))
                                 .present?(requirement.directory, requirement.name)
    present ? :installed : :missing
  end

  def request_agent_inventory!
    Agent::Commands.send_message(id, { 'type' => 'inventory.refresh' })
    true
  end

  # Manager's catalog as "folder/file" => link.
  def fetch_manager_catalog(api)
    api.manager_catalog.each_with_object({}) do |entry, catalog|
      path = Comfyui::ManagerCatalog.path(entry)
      catalog[path] = entry['url'] if path
    end
  rescue Comfyui::Error
    manager_catalog
  end

  # Legacy servers report models over HTTP; the router uses the same inventory rows as agent servers.
  def sync_routing_inventory!(listed, api)
    node_types = api.object_info_class_types
    hash = Digest::SHA256.hexdigest(JSON.generate([listed, node_types]))
    Agent::InventoryStore.store!(self, { 'hash' => hash, 'models' => listed, 'node_types' => node_types })
  rescue Comfyui::Error
    hash = Digest::SHA256.hexdigest(JSON.generate(listed))
    Agent::InventoryStore.store!(self, { 'hash' => hash, 'models' => listed, 'node_types' => [] })
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

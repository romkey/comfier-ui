# A ComfyUI workflow in API format, with {{placeholders}} where user input goes.
# The placeholders a workflow contains decide which fields its studio form shows.
class Workflow < ApplicationRecord # rubocop:disable Metrics/ClassLength
  PLACEHOLDER = /\{\{\s*(\w+)\s*\}\}/
  PLACEHOLDERS = {
    'prompt' => 'What the user asked for',
    'negative_prompt' => 'Things to avoid (optional for users)',
    'seed' => 'Random seed; random unless the user sets one',
    'width' => 'Width from the chosen aspect ratio and base resolution',
    'height' => 'Height from the chosen aspect ratio and base resolution',
    'duration' => 'Length in seconds',
    'frames' => 'Frame count: duration × frame rate + 1',
    'image' => 'Name of an image the user uploads (sent to ComfyUI first)',
    'steps' => 'Sampler steps (from Quality: fast ×0.5, standard ×1, best ×1.5)',
    'cfg' => 'Classifier-free guidance (from Prompt strength)',
    'denoise' => 'How much to change a reference image (0–1)',
    'lyrics' => 'Song lyrics for audio workflows',
    'batch_size' => 'How many outputs to generate at once'
  }.freeze
  UI_FORMAT_MESSAGE = 'is in ComfyUI\'s UI format. Use Workflow → Export (API) instead.'.freeze
  UI_EXPORT_NEEDED = 'must be the regular export (Workflow → Export), not Export (API)'.freeze

  enum :kind, GenerationKind.enum_values, validate: true

  has_many :generations, dependent: :nullify
  has_many :workflow_models, -> { order(:folder, :filename) }, dependent: :delete_all, inverse_of: :workflow
  has_many :workflow_availabilities, dependent: :delete_all

  after_save_commit :extract_requirements, if: -> { requirements_inputs_changed? }

  validates :name, presence: true, uniqueness: { scope: :kind, case_sensitive: false }
  validates :base_resolution, numericality: { only_integer: true, in: 64..4096 }
  validates :frame_rate, numericality: { only_integer: true, in: 1..120 }
  validates :steps, numericality: { only_integer: true, in: 1..150 }
  validates :guidance, numericality: { greater_than: 0, less_than_or_equal_to: 30 }
  validates :default_timeout_s, numericality: { only_integer: true, in: 60..86_400 }, allow_nil: true
  validate :graph_is_api_format
  validate :placeholders_are_known
  validate :model_list_is_valid
  before_validation :drop_models_the_graph_provides

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:position, :name) }

  def kind_info = GenerationKind.find(kind)

  # The admin form edits the per-workflow time limit in minutes; blank means the server default.
  def timeout_minutes = default_timeout_s && (default_timeout_s / 60)

  def timeout_minutes=(value)
    self.default_timeout_s = value.presence && (value.to_f * 60).round
  end

  def graph_json
    raw = @graph_json || (graph.present? ? JSON.pretty_generate(graph) : '')
    WorkflowGraphJson.utf8_string(raw)
  end

  def graph_json=(text)
    @graph_json = WorkflowGraphJson.utf8_string(text)
    @graph_json_error = nil
    self.graph = JSON.parse(WorkflowGraphJson.normalize(@graph_json))
  rescue JSON::ParserError => e
    @graph_json_error = e.message.truncate(200)
    self.graph = {}
  end

  def self.normalize_graph_json(text) = WorkflowGraphJson.normalize(text)

  def placeholders
    @placeholders ||= Set.new.tap { |found| collect_placeholders(graph, found) }
  end

  def uses?(*names) = names.any? { placeholders.include?(it.to_s) }

  def graph=(value)
    @placeholders = nil
    @required_models = nil
    super
  end

  def extra_models=(value)
    @required_models = nil
    super
  end

  # Every model file this workflow needs: the admin's list first (it carries download links),
  # then anything the graph's loader nodes reference that the list doesn't mention.
  def required_models
    @required_models ||= WorkflowModels.merge(extra_models.map { ModelRequirement.from_h(it) },
                                              WorkflowModels.infer(graph))
  end

  def self.model_directories = all.flat_map(&:required_models).map(&:directory).uniq

  def required_models_text
    @required_models_text || required_models.map(&:to_line).join("\n")
  end

  def required_models_text=(text)
    @required_models_text = text
    lines = text.to_s.lines.map(&:strip).reject { it.empty? || it.start_with?('#') }
    self.extra_models = lines.map { ModelRequirement.parse_line(it).to_h }
  end

  # Picks up download links from a UI-format export (Workflow → Export), which records
  # `properties.models` on loader nodes the way ComfyUI's templates do.
  def import_models(json)
    data = JSON.parse(json.to_s)
    return @models_import_error = UI_EXPORT_NEEDED unless WorkflowModels.ui_format?(data)

    self.ui_graph = data
    imported = WorkflowModels.from_ui_workflow(data)
    current = extra_models.map { ModelRequirement.from_h(it) }
    self.extra_models = WorkflowModels.merge(current, imported).map(&:to_h)
    @required_models_text = nil
    imported.size
  rescue JSON::ParserError => e
    @models_import_error = "isn't valid JSON: #{e.message.truncate(200)}"
  end

  # Agent-server requirements: models from the API graph, the UI export, and the admin list.
  def agent_requirements = Agent::Requirements.for(self)

  def extract_requirements
    Agent::Requirements.extract!(self)
    RecomputeAvailabilityJob.perform_later(workflow_id: id)
    EnrichWorkflowModelsJob.perform_later(self)
  end

  private

  def requirements_inputs_changed?
    %w[graph ui_graph extra_models].any? { saved_change_to_attribute?(it) } || structure_hash.blank?
  end

  # The models textarea shows what the graph needs too; keeping those lines unless they add a
  # link would leave stale entries behind after the graph stops using a model.
  def drop_models_the_graph_provides
    inferred = WorkflowModels.infer(graph).map(&:key)
    self.extra_models = extra_models.reject { it['url'].blank? && inferred.include?([it['directory'], it['name']]) }
  end

  def model_list_is_valid
    errors.add(:models_file, @models_import_error) if @models_import_error
    extra_models.map { ModelRequirement.from_h(it) }.flat_map(&:problems).each { errors.add(:required_models_text, it) }
  end

  def collect_placeholders(node, found)
    case node
    when Hash then node.each_value { collect_placeholders(it, found) }
    when Array then node.each { collect_placeholders(it, found) }
    when String then node.scan(PLACEHOLDER) { |(name)| found << name }
    end
  end

  def graph_is_api_format
    return errors.add(:graph_json, "isn't valid JSON: #{@graph_json_error}") if @graph_json_error
    return errors.add(:graph_json, 'must be a ComfyUI API-format workflow') unless graph.is_a?(Hash) && graph.any?
    return errors.add(:graph_json, UI_FORMAT_MESSAGE) if graph.key?('nodes') && graph.key?('links')

    errors.add(:graph_json, 'must contain nodes with class_type and inputs') unless graph.values.all? { api_node?(it) }
  end

  def api_node?(node) = node.is_a?(Hash) && node['class_type'].is_a?(String) && node['inputs'].is_a?(Hash)

  def placeholders_are_known
    unknown = placeholders.to_a - PLACEHOLDERS.keys
    errors.add(:graph_json, "uses unknown placeholders: #{unknown.sort.join(', ')}") if unknown.any?
  end
end

# What runs a workflow on a server. ComfyUI runs node graphs; mflux and mlx-video are native Apple
# Silicon (MLX) tools that run a recipe instead. An agent reports which engines it has.
class WorkflowEngine
  Engine = Data.define(:key, :label, :kinds) do
    def to_s = label
    def to_param = key
    def comfyui? = key == 'comfyui'
    def allows_kind?(kind) = kinds.nil? || kinds.include?(kind.to_s)
  end

  ALL = [
    Engine.new(key: 'comfyui', label: 'ComfyUI', kinds: nil),
    Engine.new(key: 'mflux', label: 'mflux', kinds: %w[image]),
    Engine.new(key: 'mlx_video', label: 'MLX video', kinds: %w[video])
  ].freeze

  BY_KEY = ALL.index_by(&:key).freeze

  def self.all = ALL
  def self.keys = BY_KEY.keys
  def self.find(key) = BY_KEY.fetch(key.to_s)
  def self.find_by(key) = BY_KEY[key.to_s]
  def self.label_for(key) = find_by(key)&.label || key.to_s
  def self.enum_values = keys.index_by(&:itself)
end

# The four kinds of media users can generate. Each has its own studio page and nav entry.
# `label` is for nav and headings; `noun` reads naturally mid-sentence ("Add a 3D model workflow").
class GenerationKind
  Kind = Data.define(:key, :label, :noun, :icon, :path, :default_duration) do
    def to_s = label
    def to_param = key
  end

  ALL = [
    Kind.new(key: 'image', label: 'Image', noun: 'image', icon: 'bi-image', path: '/image', default_duration: nil),
    Kind.new(key: 'video', label: 'Video', noun: 'video', icon: 'bi-film', path: '/video', default_duration: 5),
    Kind.new(key: 'audio', label: 'Audio', noun: 'audio', icon: 'bi-music-note-beamed', path: '/audio',
             default_duration: 10),
    Kind.new(key: 'model_3d', label: '3D Model', noun: '3D model', icon: 'bi-box', path: '/3d', default_duration: nil)
  ].freeze

  BY_KEY = ALL.index_by(&:key).freeze

  def self.all = ALL
  def self.keys = BY_KEY.keys
  def self.find(key) = BY_KEY.fetch(key.to_s)
  def self.enum_values = keys.index_by(&:itself)
end

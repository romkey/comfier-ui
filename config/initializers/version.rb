# The newest v* git tag is the canonical version; release builds bake it in as APP_VERSION
# (e.g. "0.51.0+abc1234"). Local checkouts fall back to `git describe`, then "dev".
module AppVersion
  def self.current
    @current ||= ENV['APP_VERSION'].presence || git_describe || 'dev'
  end

  def self.semver = current.split('+', 2).first.delete_prefix('v')

  def self.commit = current.split('+', 2)[1]

  def self.git_describe
    out = IO.popen(%w[git describe --tags --always --dirty], chdir: Rails.root.to_s, err: File::NULL, &:read)
    out.strip.presence if Process.last_status&.success?
  rescue SystemCallError
    nil
  end
end

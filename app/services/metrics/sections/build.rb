module Metrics
  module Sections
    class Build < Base
      def collect
        gauge('comfier_build_info', 'The running version of Comfier. Always 1.',
              [[{ version: AppVersion.semver, commit: AppVersion.commit.to_s, ruby: RUBY_VERSION,
                  rails: Rails.version }, 1]])
      end
    end
  end
end

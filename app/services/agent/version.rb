# frozen_string_literal: true

module Agent
  # The agent version this build of Comfier ships (comfyui/comfier_agent), compared with the
  # agent_version each server reports in its hello.
  module Version
    SOURCE = Rails.root.join('comfyui/comfier_agent/comfier_agent/__init__.py')

    class << self
      def expected
        return @expected if defined?(@expected)

        @expected = SOURCE.exist? ? SOURCE.read[/^__version__\s*=\s*["']([^"']+)["']/, 1] : nil
      end

      # :current, :outdated (the server should update its agent), :newer (Comfier should be
      # updated), or :unknown when either side is missing or unparseable.
      def compare(reported, expected: self.expected)
        mine = parse(expected)
        theirs = parse(reported)
        return :unknown unless mine && theirs
        return :current if theirs == mine

        theirs < mine ? :outdated : :newer
      end

      private

      def parse(version)
        Gem::Version.new(version.to_s.strip) if version.present? && Gem::Version.correct?(version.to_s.strip)
      end
    end
  end
end

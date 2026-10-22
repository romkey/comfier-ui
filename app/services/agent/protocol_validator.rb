# frozen_string_literal: true

module Agent
  # Validates agent messages against protocol/agent-v1.schema.json, the schema shared with the
  # agent package. Each message is checked against the definition for its own type, so errors
  # name the actual problem instead of every oneOf branch.
  class ProtocolValidator
    SCHEMA_PATH = Rails.root.join('protocol/agent-v1.schema.json')
    INBOUND_TYPES = %w[
      hello status inventory object_info bye
      job.request job.accepted job.rejected job.progress job.completed job.failed job.cancelled
      model.download.progress model.download.completed model.download.failed model.download.cancelled
      model.deleted model.delete.failed
    ].freeze
    OUTBOUND_TYPES = %w[
      job.assign job.cancel model.download model.download.cancel model.delete
      config.pause config.resume inventory.refresh object_info.request
    ].freeze

    class ValidationError < StandardError; end

    class << self
      # Returns :ok, or :unknown for a type this frontend doesn't handle (ignored per the protocol).
      def validate_inbound!(message)
        raise ValidationError, 'message must be a JSON object' unless message.is_a?(Hash)
        return :unknown unless INBOUND_TYPES.include?(message['type'])

        check!(message)
        :ok
      end

      def validate_outbound!(message)
        raise ValidationError, "unknown outbound type #{message['type'].inspect}" unless
          OUTBOUND_TYPES.include?(message['type'])

        check!(message)
      rescue ValidationError => e
        raise if Rails.env.local?

        Rails.logger.error("[Agent] outbound message failed validation: #{e.message}")
      end

      def errors_for(message)
        schema = definition(message['type'])
        return ["unknown type #{message['type'].inspect}"] unless schema

        schema.validate(message).pluck('error')
      end

      private

      def check!(message)
        errors = errors_for(message)
        raise ValidationError, errors.first(3).join('; ') if errors.any?

        true
      end

      def definition(type)
        return nil if type.blank?

        definitions[type] ||= root.ref("#/$defs/#{type.tr('.', '_')}")
      rescue JSONSchemer::InvalidRefPointer
        nil
      end

      def definitions = @definitions ||= {}

      def root = @root ||= JSONSchemer.schema(SCHEMA_PATH)
    end
  end
end

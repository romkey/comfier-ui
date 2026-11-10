module Api
  module V1
    class GenerationSubmission
      class Conflict < StandardError; end

      Result = Data.define(:generation, :replayed)

      def initialize(user, attributes, idempotency_key: nil)
        @user = user
        @attributes = attributes
        @key = idempotency_key
      end

      def call
        # The lock makes checking the receipt and creating the generation atomic across API tokens,
        # processes, and concurrent retries. Database uniqueness is a second line of defense.
        @user.with_lock { submit }
      end

      private

      def submit
        receipt = @key && ApiGenerationRequest.find_by(user: @user, key_digest: key_digest)
        return replay(receipt) if receipt

        generation = @user.generations.create!(@attributes)
        ApiGenerationRequest.create!(user: @user, key_digest:, request_digest:, generation:) if @key
        SubmitGenerationJob.perform_later(generation)
        Result.new(generation:, replayed: false)
      end

      def replay(receipt)
        if receipt.request_digest != request_digest
          raise Conflict, 'This idempotency key was already used with different inputs.'
        end
        raise Conflict, 'The generation associated with this idempotency key was deleted.' unless receipt.generation

        Result.new(generation: receipt.generation, replayed: true)
      end

      def key_digest = Digest::SHA256.hexdigest(@key)

      def request_digest
        @request_digest ||= Digest::SHA256.hexdigest(canonical_attributes.to_json)
      end

      def canonical_attributes
        @attributes.sort.to_h.transform_values do |value|
          if value.is_a?(ActionDispatch::Http::UploadedFile)
            { filename: value.original_filename, content_type: value.content_type,
              sha256: Digest::SHA256.file(value.tempfile.path).hexdigest }
          else
            value.to_s
          end
        end
      end
    end
  end
end

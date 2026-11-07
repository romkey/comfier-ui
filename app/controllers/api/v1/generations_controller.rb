module Api
  module V1
    class GenerationsController < BaseController
      include OutputServing

      before_action :set_generation, only: %i[show cancel output]

      def index
        page = positive_integer(params[:page], 1)
        per_page = [positive_integer(params[:per_page], 25), 100].min
        records = current_user.generations.recent.with_attached_outputs
                              .offset((page - 1) * per_page).limit(per_page + 1).to_a
        more = records.length > per_page
        render json: { generations: records.first(per_page).map { |generation| generation_json(generation) },
                       pagination: { page:, per_page:, next_page: more ? page + 1 : nil } }
      end

      def show
        render json: { generation: generation_json(@generation) }
      end

      def create
        result = GenerationSubmission.new(current_user, generation_params.to_h,
                                          idempotency_key: idempotency_key).call
        response.headers['Location'] = api_v1_generation_url(result.generation)
        response.headers['Idempotency-Replayed'] = result.replayed.to_s
        render json: { generation: generation_json(result.generation) }, status: result.replayed ? :ok : :created
      rescue GenerationSubmission::Conflict => e
        render_error(:conflict, 'idempotency_conflict', e.message)
      end

      def cancel
        unless GenerationCanceller.call(@generation).cancelled
          return render_error(:conflict, 'not_cancellable', 'This generation is no longer queued or running.')
        end

        render json: { generation: generation_json(@generation.reload) }
      end

      def output
        attachment = @generation.outputs.find(params[:output_id])
        serve_output(attachment, download: true)
        prevent_caching
      end

      private

      def idempotency_key
        key = request.headers['Idempotency-Key']
        if key && (key.blank? || key.bytesize > 255)
          raise ActionController::BadRequest, 'Idempotency-Key must contain 1–255 bytes.'
        end

        key
      end

      def set_generation
        @generation = current_user.generations.find(params[:id])
      end

      def generation_params
        attributes = params.expect(generation: %i[workflow_id prompt negative_prompt seed aspect_ratio duration
                                                  input_image quality cfg_level denoise lyrics batch_size])
        image = attributes[:input_image]
        if image.present? && !image.is_a?(ActionDispatch::Http::UploadedFile)
          raise ActionController::BadRequest, 'input_image must be a multipart file upload.'
        end

        attributes
      end

      def positive_integer(value, default)
        return default if value.nil?

        number = Integer(value.to_s, 10)
        raise ActionController::BadRequest, 'Pagination values must be positive integers.' unless number.positive?

        number
      rescue ArgumentError
        raise ActionController::BadRequest, 'Pagination values must be positive integers.'
      end

      def generation_json(generation)
        {
          id: generation.id, workflow_id: generation.workflow_id, workflow_name: generation.style_name,
          kind: generation.kind, status: generation.status, prompt: generation.prompt,
          negative_prompt: generation.negative_prompt, parameters: generation.parameters,
          progress: { phase: generation.agent_phase, fraction: generation.agent_progress },
          error: generation.error_message, created_at: generation.created_at, completed_at: generation.completed_at,
          outputs: generation.outputs.map { |attachment| output_json(generation, attachment) }
        }
      end

      def output_json(generation, attachment)
        blob = attachment.blob
        {
          id: attachment.id, filename: blob.filename.to_s, content_type: blob.content_type, byte_size: blob.byte_size,
          download_url: output_api_v1_generation_url(generation, output_id: attachment.id)
        }
      end
    end
  end
end

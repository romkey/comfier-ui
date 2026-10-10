# frozen_string_literal: true

module Agent
  # Turns a new generation into an agent job: fills the workflow (inputs become
  # comfier-input://<id> references the agent resolves), records its job type, then routes it.
  class Submission
    INPUT_ID = 'in_0'

    def self.enqueue!(generation) = new(generation).enqueue!

    def initialize(generation)
      @generation = generation
    end

    def enqueue!
      workflow = @generation.workflow
      image = prepare_inputs!
      requirements = Requirements.for(workflow)
      @generation.update!(
        filled_workflow_json: filled_workflow(workflow, image),
        structure_hash: workflow.structure_hash || Requirements.structure_hash(workflow.graph),
        model_set_hash: Requirements.model_set_hash(requirements.models),
        work_units: WorkUnits.compute(@generation), agent_state: 'routing', status: :queued,
        submitted_at: Time.current
      )
      Router.route!(@generation)
    end

    private

    # A recipe option left blank (say an empty {{negative_prompt}}) is dropped, so the tool keeps its own
    # default instead of getting an empty flag: mlx-video's LTX negative prompt is tuned, and "" undoes it.
    def filled_workflow(workflow, image)
      filled = WorkflowRenderer.render(workflow.graph, @generation.placeholder_values(image:))
      workflow.comfyui? ? filled : filled.reject { |_key, value| value == '' }
    end

    def prepare_inputs!
      return unless @generation.input_image.attached?

      blob = @generation.input_image.blob
      GenerationInput.find_or_initialize_by(generation_id: @generation.id, input_id: INPUT_ID).update!(
        storage_key: blob.key, filename: blob.filename.sanitized, mime: blob.content_type, bytes: blob.byte_size,
        sha256: nil
      )
      "comfier-input://#{INPUT_ID}"
    end
  end
end

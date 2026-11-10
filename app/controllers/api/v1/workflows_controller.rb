module Api
  module V1
    class WorkflowsController < BaseController
      def index
        render json: { workflows: Workflow.enabled.ordered.map { |workflow| workflow_json(workflow) } }
      end

      private

      def workflow_json(workflow)
        {
          id: workflow.id, name: workflow.name, kind: workflow.kind, description: workflow.description,
          inputs: WorkflowInputs.new(workflow).as_json
        }
      end
    end
  end
end

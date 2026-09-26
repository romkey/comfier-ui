# Reads ComfyUI export uploads and routes API vs regular exports to the right workflow fields.
class WorkflowExportRouter
  Result = Data.define(:graph_content, :models_content, :swap_notice)

  def self.route(workflow, graph_file:, models_file:) = new(workflow).route(graph_file:, models_file:)

  def initialize(workflow)
    @workflow = workflow
  end

  def route(graph_file:, models_file:)
    graph_data, models_data, swap_notice = classify_uploads(graph_file, models_file)
    graph_content = content_for_graph(graph_file, graph_data, models_data, models_file)
    models_content = content_for_models(models_data)
    import_invalid_models_file(models_file, models_data, models_content)

    Result.new(graph_content:, models_content:, swap_notice:)
  end

  private

  def classify_uploads(graph_file, models_file)
    graph_data = read_json_file(graph_file)
    models_data = read_json_file(models_file)
    swap_notice = swapped_notice(graph_data, models_data)
    graph_data, models_data = swap_uploads(graph_data, models_data) if swap_notice
    graph_data, models_data = route_ui_only_graph_upload(graph_data, models_data, models_file)
    [graph_data, models_data, swap_notice]
  end

  def swapped_notice(graph_data, models_data)
    return unless graph_data && models_data
    return unless WorkflowModels.ui_format?(graph_data) && WorkflowModels.api_format?(models_data)

    'The two export files looked swapped, so Comfier applied them to the right fields.'
  end

  def swap_uploads(graph_data, models_data)
    [models_data, graph_data]
  end

  def route_ui_only_graph_upload(graph_data, models_data, models_file)
    return [graph_data, models_data] unless graph_data && models_file.nil? && WorkflowModels.ui_format?(graph_data)

    [nil, graph_data]
  end

  def content_for_graph(graph_file, graph_data, models_data, models_file)
    if graph_data && WorkflowModels.api_format?(graph_data)
      JSON.pretty_generate(graph_data)
    elsif graph_file.respond_to?(:read) && !ui_only_graph_upload?(graph_file, models_file, graph_data, models_data)
      graph_file.read
    end
  end

  def content_for_models(models_data)
    JSON.generate(models_data) if models_data && WorkflowModels.ui_format?(models_data)
  end

  def import_invalid_models_file(models_file, models_data, models_content)
    return if models_content.present? || !models_file.respond_to?(:read) || models_data.nil?

    @workflow.import_models(models_file.read)
  end

  def ui_only_graph_upload?(graph_file, models_file, graph_data, models_data)
    return false unless graph_file.respond_to?(:read) && models_file.nil?

    (graph_data && WorkflowModels.ui_format?(graph_data)) ||
      (graph_data.nil? && models_data && WorkflowModels.ui_format?(models_data))
  end

  def read_json_file(file)
    return unless file.respond_to?(:read)

    JSON.parse(file.read)
  rescue JSON::ParserError
    nil
  ensure
    file.rewind if file.respond_to?(:rewind)
  end
end

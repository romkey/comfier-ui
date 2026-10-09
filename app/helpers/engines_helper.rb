# Labels for the engines that run workflows: ComfyUI, mflux, MLX video.
module EnginesHelper
  def engine_badge(key)
    tag.span(WorkflowEngine.label_for(key), class: 'badge text-bg-secondary-subtle fw-medium me-1')
  end

  def server_engine_badges(backend)
    safe_join(backend.engines.keys.sort_by { WorkflowEngine.keys.index(it) || WorkflowEngine.keys.size }
                     .map { engine_badge(it) })
  end
end

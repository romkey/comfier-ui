# Labels for the engines that run workflows: ComfyUI, mflux, MLX video.
module EnginesHelper
  def engine_badge(key)
    tag.span(WorkflowEngine.label_for(key), class: 'badge text-bg-secondary-subtle fw-medium me-1')
  end

  AGENT_PACKAGE = 'git+https://github.com/romkey/comfier-ui.git#subdirectory=comfyui/comfier_agent'.freeze

  # Installs the agent as a standalone service on an Apple Silicon Mac, with mflux.
  def mac_install_snippet(key)
    url = Agent::Dispatcher.base_url
    # The agent refuses a plain-http Comfier unless told it's on purpose (local and LAN installs).
    insecure = ' --allow-insecure' if url.start_with?('http://')
    <<~TEXT
      uv tool install --python 3.12 "comfier-agent[mac] @ #{AGENT_PACKAGE}"
      comfier-agent setup --url #{url} --key #{key}#{insecure}
      comfier-agent service install
    TEXT
  end

  def server_engine_badges(backend)
    safe_join(backend.engines.keys.sort_by { WorkflowEngine.keys.index(it) || WorkflowEngine.keys.size }
                     .map { engine_badge(it) })
  end
end

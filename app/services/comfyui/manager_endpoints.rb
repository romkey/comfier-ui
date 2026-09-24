module Comfyui
  # ComfyUI-Manager 4's API (under /v2), for backends started with --enable-manager.
  module ManagerEndpoints
    # Manager's version string, or nil when Manager isn't enabled.
    def manager_version
      perform(Net::HTTP::Get.new(uri('v2/manager/version'))).body.to_s.strip.presence
    rescue NotFound
      nil
    end

    def manager_catalog = Array(get_json('v2/externalmodel/getlist', mode: 'cache')['models'])

    # Queues a catalog entry for download. Manager only accepts entries from its own catalog.
    def manager_install_model(entry)
      perform(json_request(Net::HTTP::Post, 'v2/manager/queue/install_model', entry))
      perform(json_request(Net::HTTP::Post, 'v2/manager/queue/start', {}))
    rescue PromptRejected
      raise Error, "ComfyUI-Manager on #{backend.name} rejected #{entry['filename']}"
    end

    def manager_queue_status = get_json('v2/manager/queue/status')
  end
end

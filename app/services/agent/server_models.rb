# frozen_string_literal: true

module Agent
  # The models a workflow (or every workflow on a server, or files picked from its inventory) uses on one
  # server: those installed, which a delete removes, and the downloads a reload queues afterwards. Models are
  # hashes like DownloadPlanner takes; mflux and MLX video models have 'engine', with 'folder' the engine.
  module ServerModels
    Selection = Data.define(:installed, :downloads) do
      def self.empty = new(installed: [], downloads: [])

      def +(other)
        Selection.new(installed: (installed + other.installed).uniq { ServerModels.key(it) },
                      downloads: (downloads + other.downloads).uniq { ServerModels.key(it) })
      end

      def empty? = installed.empty? && downloads.empty?
    end

    module_function

    def key(model) = [model['folder'], model['filename']]

    def for_server(backend)
      backend.workflows_for_server.map { for_workflow(it, backend) }.sum(Selection.empty)
    end

    def for_workflow(workflow, backend)
      return engine_selection(workflow, backend) unless workflow.comfyui?

      mac = MacWeights.new(backend)
      needed = Requirements.for(workflow).models
      pairs = backend.backend_models.pluck(:folder, :filename)
      Selection.new(installed: mac.models(needed).flat_map { installed_paths(it, pairs) }.uniq { key(it) },
                    downloads: downloadable(backend, mac.downloads(needed)))
    end

    # paths: "folder/filename" as the server reported them; for engine models "engine/model".
    def for_files(backend, paths)
      installed = paths.filter_map { installed_file(backend, *it.to_s.split('/', 2)) }.uniq { key(it) }
      known = for_server(backend).downloads
      Selection.new(installed:, downloads: installed.flat_map { downloads_for(known, it) }.uniq { key(it) })
    end

    # The downloads that put a picked file back: those with its own name, else a Mac stand-in for the same fp8
    # file, which some workflow downloads under the other fp16 name.
    def downloads_for(known, file)
      same = known.select { same_file?(it, file) }
      same.presence || known.select { same_file?(it, file, stand_in: true) }
    end

    def installed_file(backend, folder, filename)
      return if folder.blank? || filename.blank?

      if folder != 'comfyui' && backend.engines.key?(folder)
        return unless backend.engine_models(folder).include?(filename)

        return { 'folder' => folder, 'filename' => filename, 'engine' => folder }
      end
      { 'folder' => folder, 'filename' => filename } if backend.backend_models.exists?(folder:, filename:)
    end

    def engine_selection(workflow, backend)
      engine = workflow.engine
      return Selection.empty unless backend.runs_engine?(engine)

      have = backend.engine_models(engine) | backend.backend_models.where(folder: engine).pluck(:filename)
      models = workflow.recipe_models.map { { 'folder' => engine, 'filename' => it, 'engine' => engine } }
      Selection.new(installed: models.select { have.include?(it['filename']) },
                    downloads: backend.can_download_models? ? models : [])
    end

    # Where the server keeps a file the workflow names, allowing for folder aliases (unet is diffusion_models)
    # and models whose folder couldn't be worked out.
    def installed_paths(model, pairs)
      folders = model['folder'] == 'unknown' ? nil : ModelMatcher.folders_for(model['folder'])
      pairs.filter_map do |have_folder, filename|
        next unless folders.nil? || folders.include?(have_folder)
        next unless names_match?(filename, model['filename'], loosely: folders.nil?)

        { 'folder' => have_folder, 'filename' => filename }
      end
    end

    def names_match?(have, want, loosely:)
      have == want || (loosely && File.basename(have) == File.basename(want.to_s))
    end

    def downloadable(backend, models)
      return [] unless backend.can_download_models?

      models.select do |model|
        model['url'].present? &&
          ModelRequirement.new(directory: model['folder'], name: model['filename'], url: model['url']).problems.empty?
      end
    end

    def same_file?(download, file, stand_in: false)
      return download['engine'] == file['engine'] && download['filename'] == file['filename'] if file['engine']

      ModelMatcher.folders_for(download['folder']).include?(file['folder']) &&
        names_for(download, stand_in:).include?(file['filename'])
    end

    # A Mac stand-in's download can be named apart from the copy already there; both stand in for one fp8 file.
    def names_for(download, stand_in:)
      fp8 = download['replaces']
      return [download['filename']] if !stand_in || fp8.blank?

      [MacWeights.fp16_name(fp8), MacWeights.converted_name(fp8)]
    end
  end
end

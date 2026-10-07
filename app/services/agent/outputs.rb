# frozen_string_literal: true

module Agent
  # Which files an agent may upload as results. The server owner controls the bytes and may not
  # be the person viewing them, so the type is detected from the contents and must agree with the
  # file extension. Only media and 3D formats are accepted; SVG and HTML never are.
  module Outputs
    KINDS = {
      'image' => { 'png' => 'image/png', 'jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg', 'webp' => 'image/webp',
                   'gif' => 'image/gif' },
      'video' => { 'mp4' => 'video/mp4', 'webm' => 'video/webm', 'mov' => 'video/quicktime' },
      'audio' => { 'wav' => 'audio/x-wav', 'mp3' => 'audio/mpeg', 'flac' => 'audio/flac', 'ogg' => 'audio/ogg' },
      '3d' => { 'glb' => 'model/gltf-binary', 'gltf' => 'model/gltf+json', 'obj' => 'model/obj', 'ply' => 'model/ply',
                'fbx' => 'application/octet-stream' }
    }.freeze
    # Detected types (from Marcel) that each extension may legitimately have.
    DETECTED = {
      'png' => %w[image/png], 'jpg' => %w[image/jpeg], 'jpeg' => %w[image/jpeg], 'webp' => %w[image/webp],
      'gif' => %w[image/gif], 'mp4' => %w[video/mp4 video/quicktime], 'webm' => %w[video/webm audio/webm],
      'mov' => %w[video/quicktime video/mp4], 'wav' => %w[audio/x-wav audio/wav audio/vnd.wave],
      'mp3' => %w[audio/mpeg], 'flac' => %w[audio/flac audio/x-flac], 'ogg' => %w[audio/ogg video/ogg audio/opus]
    }.freeze
    TEXT_3D = %w[gltf obj ply].freeze
    INLINE_TYPES = KINDS.slice('image', 'video', 'audio').values.flat_map(&:values).uniq.freeze
    THUMBNAIL_TYPES = %w[image/png image/jpeg image/webp].freeze
    # A still the agent renders of a 3D result, kept as the generation's poster rather than as an output.
    PREVIEW = 'preview'
    MAX_FILENAME = 120
    UNSAFE_CHARS = /[\u0000-\u001f\u007f\u200e\u200f\u202a-\u202e\u2066-\u2069]/

    Verdict = Data.define(:ok, :kind, :content_type, :filename, :error)

    module_function

    def max_file_bytes = ENV.fetch('AGENT_MAX_OUTPUT_FILE_GB', 4).to_f.gigabytes
    def max_job_bytes = ENV.fetch('AGENT_MAX_OUTPUT_JOB_GB', 10).to_f.gigabytes
    def max_preview_bytes = ENV.fetch('AGENT_MAX_PREVIEW_MB', 25).to_f.megabytes

    def sanitize_filename(name)
      base = File.basename(name.to_s.tr('\\', '/')).gsub(UNSAFE_CHARS, '').strip
      base = base.delete_prefix('.') while base.start_with?('.')
      ext = File.extname(base)
      stem = File.basename(base, ext)[0, MAX_FILENAME - ext.length]
      "#{stem.presence || 'output'}#{ext.downcase}"
    end

    def check(io, filename)
      name = sanitize_filename(filename)
      ext = File.extname(name).delete_prefix('.').downcase
      kind, types = KINDS.find { |_kind, map| map.key?(ext) }
      return reject(name, "#{ext.presence || 'files without an extension'} isn't an allowed output type") unless kind

      detected = Marcel::MimeType.for(io, name: nil)
      io.rewind if io.respond_to?(:rewind)
      return reject(name, "the contents aren't a valid .#{ext} file") unless contents_match?(ext, detected, io)

      Verdict.new(ok: true, kind:, content_type: types[ext], filename: name, error: nil)
    end

    def contents_match?(ext, detected, io)
      return DETECTED.fetch(ext).include?(detected) if DETECTED.key?(ext)
      return glb?(io) if ext == 'glb'
      return fbx?(io) if ext == 'fbx'

      TEXT_3D.include?(ext) && !markup?(io)
    end

    def glb?(io) = peek(io, 4) == 'glTF'

    def fbx?(io)
      head = peek(io, 23)
      head.start_with?('Kaydara FBX Binary') || !markup?(io)
    end

    def markup?(io)
      head = peek(io, 512).to_s.lstrip.downcase
      head.start_with?('<') || head.include?('<script') || head.include?('<html') || head.include?('<svg')
    end

    def peek(io, bytes)
      data = io.read(bytes).to_s
      io.rewind if io.respond_to?(:rewind)
      data.b
    end

    def reject(name, error) = Verdict.new(ok: false, kind: nil, content_type: nil, filename: name, error:)

    def inline?(content_type) = INLINE_TYPES.include?(content_type)

    def preview?(output) = output.kind == PREVIEW

    def model?(attachment) = KINDS['3d'].value?(attachment.content_type.to_s)

    # Attached in upload order, so the first 3D output is the one the agent drew the preview of.
    def attach!(gen, outputs)
      previews, files = outputs.sort_by(&:id).partition { preview?(it) }
      files.each do |output|
        blob = ActiveStorage::Blob.find_by(key: output.storage_key)
        gen.outputs.attach(blob) if blob && gen.outputs.none? { it.blob_id == blob.id }
      end
      attach_preview!(gen, previews.first) if files.any? { it.kind == '3d' }
      discard_unused_previews!(previews)
      discard_earlier_attempts!(gen, outputs)
    end

    def attach_preview!(gen, preview)
      blob = preview && ActiveStorage::Blob.find_by(key: preview.storage_key)
      gen.output_poster.attach(blob) if blob && !gen.output_poster.attached?
    end

    def discard_unused_previews!(previews)
      ActiveStorage::Blob.where(key: previews.filter_map(&:storage_key)).where.missing(:attachments)
                         .find_each(&:purge_later)
    end

    # Uploads from attempts that didn't finish are never attached, so their files would otherwise stay
    # in storage.
    def discard_earlier_attempts!(gen, kept)
      stale = gen.generation_outputs.where.not(id: kept.map(&:id))
      keys = stale.filter_map(&:storage_key)
      ActiveStorage::Blob.where(key: keys).where.missing(:attachments).find_each(&:purge_later)
      stale.delete_all
    end
  end
end

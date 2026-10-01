namespace :video_posters do
  desc 'Extract first-frame posters for succeeded videos that do not have one yet'
  task extract: :environment do
    abort 'ffmpeg is not available. Install ffmpeg or set FFMPEG to its path.' unless VideoPosterExtractor.available?

    scope = Generation.video.succeeded.with_attached_outputs.with_attached_output_poster
    total = 0
    ok = 0

    scope.find_each do |generation|
      next if generation.output_poster.attached?
      next unless generation.outputs.any? { |output| output.content_type.to_s.start_with?('video/') }

      total += 1
      ok += 1 if VideoPosterExtractor.call(generation)
      print '.' if (total % 50).zero?
    end

    puts "\nProcessed #{total} videos, poster saved for #{ok}."
  end
end

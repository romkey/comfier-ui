# Open Graph and Twitter card tags so a public link unfurls with a preview in chat apps and social sites.
# They point at the token-guarded routes, so previews stop working when the link is revoked, and they leave
# out the prompt, which the public page doesn't show either.
module PublicSharesHelper
  def public_share_meta_tags(generation)
    output = primary_result_output(generation)
    tags = { 'og:site_name' => 'Comfier', 'og:title' => 'Shared result', 'og:description' => 'Made with Comfier',
             'og:url' => public_share_url(generation.public_token), 'og:type' => 'website' }
    tags.merge!(public_share_media_tags(generation, output)) if output
    tags['twitter:card'] = tags.key?('og:image') ? 'summary_large_image' : 'summary'

    safe_join(tags.map { |property, content| tag.meta(property:, content:) }, "\n")
  end

  private

  def public_share_media_tags(generation, output)
    url = public_share_output_url(generation.public_token, generation.outputs.sort_by(&:id).index(output))
    type = output.content_type.to_s
    case type
    when %r{\Aimage/} then public_share_image_tags(url, type, output.blob.metadata)
    when %r{\Avideo/} then public_share_video_tags(generation, url, type)
    when %r{\Aaudio/} then public_share_audio_tags(generation, url, type)
    else public_share_poster_tags(generation)
    end
  end

  def public_share_image_tags(url, type, metadata)
    { 'og:image' => url, 'og:image:type' => type, 'og:image:width' => metadata['width'],
      'og:image:height' => metadata['height'] }.compact
  end

  def public_share_video_tags(generation, url, type)
    { 'og:type' => 'video.other', 'og:video' => url, 'og:video:secure_url' => (url if url.start_with?('https:')),
      'og:video:type' => type }.compact.merge(public_share_poster_tags(generation))
  end

  def public_share_audio_tags(generation, url, type)
    tags = { 'og:type' => 'music.song', 'og:audio' => url, 'og:audio:type' => type }
    image = generation.album_art_image
    return tags unless image

    tags.merge(public_share_image_tags(public_share_cover_url(generation.public_token), image.content_type,
                                       image.blob.metadata))
  end

  def public_share_poster_tags(generation)
    poster = generation.output_poster
    return {} unless poster.attached?

    public_share_image_tags(public_share_poster_url(generation.public_token), poster.content_type, poster.blob.metadata)
  end
end

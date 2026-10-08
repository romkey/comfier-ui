module PublicLinksHelper
  # "12 views · last 3:42 PM", for the link's owner and admins.
  def public_view_summary(generation)
    count = generation.public_view_count
    return 'No views yet' if count.zero?

    safe_join(["#{number_with_delimiter(count)} #{'view'.pluralize(count)} · last ",
               friendly_time(generation.public_last_viewed_at)])
  end
end

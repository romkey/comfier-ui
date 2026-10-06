// Video tags with a poster can play audio but show no picture after Turbo navigation.
// https://github.com/hotwired/turbo-rails/issues/576
function reloadPosterVideos(root = document) {
  root.querySelectorAll("video.output-media[poster]").forEach((video) => {
    video.load()
  })
}

document.addEventListener("turbo:load", () => reloadPosterVideos())
document.addEventListener("pageshow", (event) => {
  if (event.persisted) reloadPosterVideos()
})

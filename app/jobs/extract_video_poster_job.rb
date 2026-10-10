# Superseded by ProcessVideoOutputJob, which also makes the video browser-safe. Kept so jobs queued before an
# upgrade still run.
class ExtractVideoPosterJob < ProcessVideoOutputJob
end

class ApplicationController < ActionController::Base
  include Authentication
  include PrivacyGate
  include Pagy::Method

  allow_browser versions: :modern

  stale_when_importmap_changes
end

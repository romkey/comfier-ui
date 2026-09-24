module Admin
  class BaseController < ApplicationController
    include SettingsNav

    before_action :require_admin
  end
end

class PublicLinksController < ApplicationController
  include SettingsNav

  def show
    @generations = current_user.generations.publicly_linked.succeeded.recent.with_attached_outputs
  end

  def destroy
    current_user.revoke_all_public_links!
    redirect_to public_links_path, notice: 'All public links revoked.', status: :see_other
  end
end

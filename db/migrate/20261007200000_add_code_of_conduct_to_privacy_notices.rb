# The privacy notice now also asks users to agree to the code of conduct. Replace the existing wording with the new
# default and bump the version so everyone agrees again.
class AddCodeOfConductToPrivacyNotices < ActiveRecord::Migration[8.1]
  def up
    change_table :privacy_notices, bulk: true do |t|
      t.string :code_of_conduct_url, null: false, default: 'https://pdxhackerspace.org/code-of-conduct.pdf'
      t.string :decline_url, null: false, default: 'https://www.disney.com'
    end
    execute "UPDATE privacy_notices SET body = #{connection.quote(PrivacyNotice::DEFAULT_BODY)}, version = version + 1"
  end

  def down
    change_table :privacy_notices, bulk: true do |t|
      t.remove :decline_url, :code_of_conduct_url
    end
  end
end

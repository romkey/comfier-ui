class SimplifySharingAndAddPublicLinks < ActiveRecord::Migration[8.1]
  def change
    change_table :generations, bulk: true do |t|
      t.remove :share_prompt, type: :boolean
      t.remove :share_input, type: :boolean
      t.string :public_token
      t.datetime :public_shared_at
    end

    add_index :generations, :public_token, unique: true, where: 'public_token IS NOT NULL'

    # Nullable: nil means the member has not completed the post-privacy onboarding choice yet.
    add_column :users, :share_by_default, :boolean # rubocop:disable Rails/ThreeStateBooleanColumn
    reversible do |dir|
      dir.up { execute('UPDATE users SET share_by_default = FALSE') }
    end
  end
end

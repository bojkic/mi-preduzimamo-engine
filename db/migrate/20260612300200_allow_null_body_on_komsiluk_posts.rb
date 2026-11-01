# frozen_string_literal: true

# Make KomsilukPost#body nullable so the RetentionSweep can nullify it after
# the GDPR retention window expires (closed/expired posts past the window have
# their body set to NULL to remove personal content while keeping the record).
class AllowNullBodyOnKomsilukPosts < ActiveRecord::Migration[7.2]
  def up
    change_column_null :decidim_bih_komsiluk_posts, :body, true
  end

  def down
    # Restore NOT NULL — any rows with body IS NULL must be patched first.
    Decidim::Bih::KomsilukPost.where(body: nil).update_all(body: "") # rubocop:disable Rails/SkipsModelValidations
    change_column_null :decidim_bih_komsiluk_posts, :body, false
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Private revision bodies follow the same retention boundary as their post.
    class KomsilukPostRevision < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_komsiluk_post_revisions"
      self.filter_attributes += [:snapshot]
      belongs_to :post, class_name: "Decidim::Bih::KomsilukPost"
      belongs_to :actor, class_name: "Decidim::User", optional: true
      validates :content_revision, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :post_id }
    end
  end
end

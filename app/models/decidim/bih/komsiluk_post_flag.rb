# frozen_string_literal: true

module Decidim
  module Bih
    # Records a single citizen's flag on a KomsilukPost.
    # The unique DB index (post_id, user_id) enforces one flag per user per post.
    class KomsilukPostFlag < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_komsiluk_post_flags"

      belongs_to :post,
                 class_name: "Decidim::Bih::KomsilukPost",
                 foreign_key: :decidim_bih_komsiluk_post_id,
                 inverse_of: :flags

      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: :decidim_user_id

      validates :decidim_user_id, uniqueness: { scope: :decidim_bih_komsiluk_post_id }
    end
  end
end

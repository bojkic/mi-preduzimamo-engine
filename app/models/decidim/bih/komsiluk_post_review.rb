# frozen_string_literal: true

module Decidim
  module Bih
    # Content-free, append-only moderation decisions. Reviewer identity is private
    # to authorized moderation/audit views and disappears when its account does.
    class KomsilukPostReview < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_komsiluk_post_reviews"

      ACTIONS = %w(keep hide restore).freeze
      REASONS = %w(valid inappropriate spam personal_data duplicate inaccurate expired other).freeze

      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :post, class_name: "Decidim::Bih::KomsilukPost", foreign_key: :decidim_bih_komsiluk_post_id
      belongs_to :reviewer, class_name: "Decidim::User", optional: true

      validates :action, inclusion: { in: ACTIONS }
      validates :reason, inclusion: { in: REASONS }
      validates :previous_status, :resulting_status, inclusion: { in: KomsilukPost::STATUSES }
      validates :content_revision, numericality: { only_integer: true, greater_than: 0 }
      validates :flagged_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validate :same_organization
      validate :immutable, on: :update

      private

      def same_organization
        errors.add(:post, :invalid) unless post&.organization == organization
        errors.add(:reviewer, :invalid) if reviewer && reviewer.organization != organization
      end

      def immutable
        errors.add(:base, :invalid)
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Public update/official notice from a verified organization profile.
    class PartnerNotice < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_partner_notices"

      NOTICE_TYPES = %w(update official).freeze
      TITLE_MAX = 160
      BODY_MAX = 4_000

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :partner_profile,
                 class_name: "Decidim::Bih::PartnerProfile",
                 inverse_of: :notices

      belongs_to :author,
                 class_name: "Decidim::User",
                 optional: true

      before_validation :normalize_fields
      before_validation :set_notice_type

      validates :title, presence: true, length: { maximum: TITLE_MAX }
      validates :body, presence: true, length: { maximum: BODY_MAX }
      validates :notice_type, inclusion: { in: NOTICE_TYPES }
      validate :profile_is_verified
      validate :same_organization
      validate :official_notice_requires_official_publisher

      scope :published, -> { where.not(published_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
      scope :recent, -> { order(published_at: :desc, id: :desc) }

      def official?
        notice_type == "official"
      end

      private

      def normalize_fields
        self.title = title.to_s.strip
        self.body = body.to_s.strip
        self.published_at ||= Time.current
      end

      def set_notice_type
        self.notice_type = notice_type.to_s.presence || "update"
      end

      def profile_is_verified
        return if partner_profile&.verified?

        errors.add(:partner_profile, :unverified)
      end

      def same_organization
        return if organization.blank?

        errors.add(:partner_profile, :invalid) if partner_profile.present? && partner_profile.organization != organization
        errors.add(:author, :invalid) if author.present? && author.organization != organization
      end

      def official_notice_requires_official_publisher
        return unless official?
        return if partner_profile&.official_publisher?

        errors.add(:notice_type, :invalid)
      end
    end
  end
end

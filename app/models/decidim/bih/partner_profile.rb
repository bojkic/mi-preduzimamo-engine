# frozen_string_literal: true

module Decidim
  module Bih
    # First-class local organization profile ("Organizacija").
    class PartnerProfile < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_partner_profiles"

      KINDS = %w(
        association foundation institution public_body business local_community_body informal_group other
      ).freeze
      VERIFICATION_STATUSES = %w(draft submitted verified rejected suspended).freeze
      GOODWILL_ELIGIBLE_KINDS = %w(association foundation informal_group).freeze
      NOTICE_DIRECT_PUBLISH_KINDS = %w(institution public_body).freeze
      VOLUNTEER_OPPORTUNITY_KINDS = %w(
        association foundation institution public_body business local_community_body informal_group
      ).freeze
      VERIFICATION_DOCUMENT_CONTENT_TYPES = %w(application/pdf image/png image/jpeg).freeze
      VERIFICATION_DOCUMENT_MAX_BYTES = 10 * 1024 * 1024
      VERIFICATION_DOCUMENT_MAX_COUNT = 5
      VERIFICATION_DESCRIPTION_MIN_LENGTH = 20
      SAMPLE_CONTENT_PATTERN = /(?:\A|[^\p{L}])(?:uzorak|sample|demo|test|узорак|демо|тест)(?:\z|[^\p{L}])/i

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :local_area,
                 class_name: "Decidim::Bih::LocalArea",
                 optional: true

      belongs_to :verified_by,
                 class_name: "Decidim::User",
                 optional: true

      belongs_to :legacy_user_group,
                 class_name: "Decidim::User",
                 optional: true

      has_many :memberships,
               class_name: "Decidim::Bih::PartnerMembership",
               dependent: :destroy,
               inverse_of: :partner_profile

      has_many :notices,
               class_name: "Decidim::Bih::PartnerNotice",
               dependent: :destroy,
               inverse_of: :partner_profile

      has_many :volunteer_opportunities,
               class_name: "Decidim::Bih::VolunteerOpportunity",
               dependent: :nullify,
               inverse_of: :partner_profile

      has_many :project_submissions,
               class_name: "Decidim::Bih::PartnerProjectSubmission",
               dependent: :restrict_with_exception,
               inverse_of: :partner_profile

      has_many :contribution_needs,
               class_name: "Decidim::Bih::ContributionNeed",
               dependent: :restrict_with_exception,
               inverse_of: :partner_profile

      has_many :contribution_offers,
               class_name: "Decidim::Bih::ContributionOffer",
               dependent: :restrict_with_exception,
               inverse_of: :partner_profile

      has_many_attached :verification_documents if respond_to?(:has_many_attached)

      before_validation :normalize_fields

      validates :display_name, presence: true, length: { maximum: 255 }
      validates :legal_name, length: { maximum: 255 }, allow_blank: true
      validates :slug, presence: true, uniqueness: { scope: :decidim_organization_id }
      validates :kind, presence: true, inclusion: { in: KINDS }
      validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }
      validates :public_description, length: { maximum: 5_000 }, allow_blank: true
      validates :website, length: { maximum: 500 }, allow_blank: true
      validates :private_contact_name, length: { maximum: 255 }, allow_blank: true
      validates :private_contact_email, length: { maximum: 255 }, allow_blank: true
      validates :private_contact_phone, length: { maximum: 64 }, allow_blank: true
      validates :rejection_reason, length: { maximum: 1_000 }, allow_blank: true
      validate :local_area_belongs_to_organization
      validate :legacy_group_belongs_to_organization
      validate :acceptable_verification_documents

      scope :verified, -> { where(verification_status: "verified") }
      scope :legacy_owner_available, lambda {
        where(
          "legacy_user_group_id IS NULL OR EXISTS (" \
          "SELECT 1 FROM decidim_users legacy_group " \
          "WHERE legacy_group.id = decidim_bih_partner_profiles.legacy_user_group_id " \
          "AND legacy_group.deleted_at IS NULL " \
          "AND legacy_group.blocked_at IS NULL " \
          "AND COALESCE(legacy_group.blocked, FALSE) = FALSE)"
        )
      }
      scope :publicly_visible, -> { verified.legacy_owner_available }
      scope :goodwill_eligible, -> { publicly_visible.where(kind: GOODWILL_ELIGIBLE_KINDS) }
      scope :official_publishers, -> { publicly_visible.where(kind: NOTICE_DIRECT_PUBLISH_KINDS) }
      scope :volunteer_opportunity_eligible, -> { publicly_visible.where(kind: VOLUNTEER_OPPORTUNITY_KINDS) }

      def verified?
        verification_status == "verified"
      end

      def rejected?
        verification_status == "rejected"
      end

      def goodwill_eligible?
        verified? && legacy_owner_available? && GOODWILL_ELIGIBLE_KINDS.include?(kind)
      end

      def official_publisher?
        verified? && legacy_owner_available? && NOTICE_DIRECT_PUBLISH_KINDS.include?(kind)
      end

      def volunteer_opportunity_eligible?
        verified? && legacy_owner_available? && VOLUNTEER_OPPORTUNITY_KINDS.include?(kind)
      end

      def can_publish_notices?
        verified? && legacy_owner_available?
      end

      def verify!(by:)
        ensure_verification_content_ready!
        update!(
          verification_status: "verified",
          verified_by: by,
          verified_at: Time.current,
          rejected_at: nil,
          rejection_reason: nil
        )
      end

      def reject!(reason:, by: nil)
        update!(
          verification_status: "rejected",
          verified_by: by,
          verified_at: nil,
          rejected_at: Time.current,
          rejection_reason: reason.to_s.strip.presence
        )
      end

      def suspend!
        update!(verification_status: "suspended")
      end

      def restore!(by:)
        verify!(by:)
      end

      def display_label
        display_name
      end

      def verification_content_issues
        issues = []
        public_fields = [display_name, legal_name, public_description].compact.join(" ")
        issues << :sample_marker if public_fields.match?(SAMPLE_CONTENT_PATTERN)
        issues << :description_too_short if public_description.to_s.strip.length < VERIFICATION_DESCRIPTION_MIN_LENGTH
        issues << :duplicate_name if duplicate_verified_display_name?
        issues
      end

      private

      def ensure_verification_content_ready!
        verification_content_issues.each do |issue|
          errors.add(:base, I18n.t("decidim.bih.admin.partner_profiles.content_review.#{issue}"))
        end
        raise ActiveRecord::RecordInvalid, self if errors.any?
      end

      def duplicate_verified_display_name?
        return false if organization.blank? || display_name.blank?

        self.class
            .where(organization:, verification_status: "verified")
            .where.not(id:)
            .exists?(["LOWER(TRIM(display_name)) = ?", display_name.to_s.strip.downcase])
      end

      def legacy_owner_available?
        return true if legacy_user_group.blank?

        !legacy_user_group.blocked? && legacy_user_group.blocked_at.blank? && legacy_user_group.deleted_at.blank?
      end

      def normalize_fields
        self.display_name = display_name.to_s.strip
        self.legal_name = legal_name.to_s.strip.presence
        self.slug = (slug.presence || display_name).to_s.parameterize
        self.kind = kind.to_s
        self.verification_status = verification_status.to_s.presence || "draft"
        self.website = website.to_s.strip.presence
        self.public_description = public_description.to_s.strip.presence
        self.private_contact_name = private_contact_name.to_s.strip.presence
        self.private_contact_email = private_contact_email.to_s.strip.presence
        self.private_contact_phone = private_contact_phone.to_s.strip.presence
      end

      def local_area_belongs_to_organization
        return if local_area.blank? || organization.blank?
        return if local_area.organization == organization

        errors.add(:local_area, :invalid)
      end

      def legacy_group_belongs_to_organization
        return if legacy_user_group.blank? || organization.blank?
        return if legacy_user_group.organization == organization

        errors.add(:legacy_user_group, :invalid)
      end

      def acceptable_verification_documents
        return unless respond_to?(:verification_documents)
        return unless verification_documents.attached?

        documents = verification_documents.to_a
        if documents.length > VERIFICATION_DOCUMENT_MAX_COUNT
          errors.add(
            :verification_documents,
            I18n.t("decidim.bih.organizations.errors.documents_too_many", count: VERIFICATION_DOCUMENT_MAX_COUNT)
          )
        end

        documents.each do |document|
          if document.byte_size.to_i > VERIFICATION_DOCUMENT_MAX_BYTES
            errors.add(
              :verification_documents,
              I18n.t("decidim.bih.organizations.errors.document_too_large", max_mb: VERIFICATION_DOCUMENT_MAX_BYTES / 1.megabyte)
            )
          elsif VERIFICATION_DOCUMENT_CONTENT_TYPES.exclude?(document.content_type)
            errors.add(:verification_documents, I18n.t("decidim.bih.organizations.errors.document_invalid_type"))
          end
        end
      end
    end
  end
end

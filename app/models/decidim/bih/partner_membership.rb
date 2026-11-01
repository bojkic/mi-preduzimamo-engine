# frozen_string_literal: true

module Decidim
  module Bih
    # Membership between a real Decidim user and a local organization profile.
    class PartnerMembership < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_partner_memberships"

      ROLES = %w(owner manager volunteer_coordinator content_editor finance_contact member).freeze
      STATUSES = %w(pending accepted revoked).freeze
      MANAGER_ROLES = %w(owner manager).freeze
      VOLUNTEER_ROLES = %w(owner manager volunteer_coordinator).freeze
      CONTENT_ROLES = %w(owner manager content_editor).freeze
      FINANCE_ROLES = %w(owner manager finance_contact).freeze

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :partner_profile,
                 class_name: "Decidim::Bih::PartnerProfile",
                 inverse_of: :memberships

      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id"

      belongs_to :invited_by,
                 class_name: "Decidim::User",
                 optional: true

      validates :role, inclusion: { in: ROLES }
      validates :status, inclusion: { in: STATUSES }
      validates :user, uniqueness: { scope: :partner_profile_id }
      validate :same_organization
      validate :preserve_last_manager, on: :update
      validate :preserve_last_volunteer_manager_for_public_needs, on: :update
      around_update :serialize_profile_membership_update
      around_destroy :serialize_profile_membership_destroy

      scope :accepted, -> { where(status: "accepted", revoked_at: nil) }
      scope :pending, -> { where(status: "pending", revoked_at: nil) }
      scope :publicly_visible, -> { accepted }

      def self.for_user(user, organization:)
        return none if user.blank? || organization.blank?

        accepted.where(organization:, user:)
      end

      def accepted?
        status == "accepted" && revoked_at.blank?
      end

      def pending?
        status == "pending" && revoked_at.blank?
      end

      def accept!
        update!(status: "accepted", accepted_at: Time.current, revoked_at: nil)
      end

      def decline!
        update!(status: "revoked", accepted_at: nil, revoked_at: Time.current)
      end

      def leave!
        partner_profile.with_lock do
          lock!
          unless accepted? && may_leave?
            errors.add(:base, I18n.t("decidim.bih.organizations.leave_membership.last_manager")) if accepted?
            raise ActiveRecord::RecordInvalid, self
          end

          update!(status: "revoked", revoked_at: Time.current)
        end
      end

      def may_leave?
        return false unless accepted?
        return true unless MANAGER_ROLES.include?(role)

        partner_profile.memberships.accepted.where(role: MANAGER_ROLES).where.not(id:).exists?
      end

      def manager?
        accepted? && MANAGER_ROLES.include?(role)
      end

      def volunteer_manager?
        accepted? && VOLUNTEER_ROLES.include?(role)
      end

      def content_manager?
        accepted? && CONTENT_ROLES.include?(role)
      end

      def finance_manager?
        accepted? && FINANCE_ROLES.include?(role)
      end

      private

      # Controller actions hold this lock before checking actor authorization.
      # This callback also protects direct model updates that use normal AR saves:
      # their initial validation may have read another manager before a competing
      # update committed, so validate again while holding the common parent lock.
      # Raw SQL/update_columns bypass AR callbacks and are not workflow writes.
      def serialize_profile_membership_update
        partner_profile.with_lock do
          raise ActiveRecord::RecordInvalid, self unless valid?

          yield
        end
      end

      # A direct destroy is another way to remove a manager. Profile teardown
      # destroys every membership and is exempt; it is separately restricted by
      # the profile's dependent associations. Normal membership deletion uses
      # the same parent lock as role changes and rechecks the persisted row.
      def serialize_profile_membership_destroy
        return yield if destroyed_by_association&.name == :memberships

        partner_profile.with_lock do
          lock!
          if accepted? && MANAGER_ROLES.include?(role) &&
             !partner_profile.memberships.accepted.where(role: MANAGER_ROLES).where.not(id:).exists?
            errors.add(:base, I18n.t("decidim.bih.partner_memberships.last_manager_required"))
          end
          if accepted? && VOLUNTEER_ROLES.include?(role) && partner_profile_publicly_visible? &&
             ContributionNeed.approved_open.exists?(partner_profile:) && !another_accepted_volunteer_manager?
            errors.add(:base, I18n.t("decidim.bih.admin.partner_memberships.last_volunteer_manager_required"))
          end
          # Around callbacks are outside Rails' before-callback abort catcher.
          # Rails handles RecordNotDestroyed for both destroy and destroy!.
          raise ActiveRecord::RecordNotDestroyed.new(errors.full_messages.join(", "), self) if errors.any?

          yield
        end
      end

      def same_organization
        return if organization.blank?

        errors.add(:partner_profile, :invalid) if partner_profile.present? && partner_profile.organization != organization
        errors.add(:user, :invalid) if user.present? && user.organization != organization
        errors.add(:invited_by, :invalid) if invited_by.present? && invited_by.organization != organization
      end

      def preserve_last_volunteer_manager_for_public_needs
        return unless removing_accepted_volunteer_role?
        return unless partner_profile_publicly_visible?
        return unless ContributionNeed.approved_open.exists?(partner_profile:)
        return if another_accepted_volunteer_manager?

        errors.add(
          :base,
          I18n.t("decidim.bih.admin.partner_memberships.last_volunteer_manager_required")
        )
      end

      def preserve_last_manager
        was_manager = attribute_in_database("status") == "accepted" &&
                      attribute_in_database("revoked_at").blank? &&
                      MANAGER_ROLES.include?(attribute_in_database("role"))
        remains_manager = status == "accepted" && revoked_at.blank? && MANAGER_ROLES.include?(role)
        return unless was_manager && !remains_manager
        return if partner_profile.memberships.accepted.where(role: MANAGER_ROLES).where.not(id:).exists?

        errors.add(:base, I18n.t("decidim.bih.partner_memberships.last_manager_required"))
      end

      def removing_accepted_volunteer_role?
        was_volunteer_manager = attribute_in_database("status") == "accepted" &&
                                attribute_in_database("revoked_at").blank? &&
                                VOLUNTEER_ROLES.include?(attribute_in_database("role"))
        remains_volunteer_manager = status == "accepted" && revoked_at.blank? && VOLUNTEER_ROLES.include?(role)
        was_volunteer_manager && !remains_volunteer_manager
      end

      def partner_profile_publicly_visible?
        PartnerProfile.publicly_visible.exists?(id: partner_profile_id, decidim_organization_id: decidim_organization_id)
      end

      def another_accepted_volunteer_manager?
        partner_profile.memberships.accepted.where(role: VOLUNTEER_ROLES).where.not(id:).exists?
      end
    end
  end
end

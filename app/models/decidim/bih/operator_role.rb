# frozen_string_literal: true

module Decidim
  module Bih
    # Capability-scoped BIH operator role.
    #
    # Moderators may be limited to explicitly assigned boards. Other capabilities
    # remain organization-scoped, and every grant expires unless renewed.
    class OperatorRole < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_operator_roles"

      ROLES = %w(
        komsiluk_moderator
        debate_facilitator
        volunteer_reviewer
        community_reviewer
        report_triager
        broadcast_operator
        support_agent
        general_support_agent
        analytics_viewer
        rewards_operator
        release_approver
      ).freeze

      # Keep retired roles in ROLES so existing rows remain readable and valid,
      # but do not offer them for new grants when the platform has no effective
      # destination for the advertised capability. Native Decidim debate
      # moderation still requires a native process/component role; the BIH
      # debate_facilitate permission is not consumed by any route or service.
      GRANTABLE_ROLES = (ROLES - %w(debate_facilitator release_approver)).freeze

      # Case-bound support messaging deliberately requires read access to the
      # case object. A support_agent therefore needs at least one companion
      # workflow role that supplies reports, Goodwill, or volunteering reads.
      ROLE_PREREQUISITES = {
        "support_agent" => {
          any_of: %w(report_triager volunteer_reviewer rewards_operator)
        }
      }.freeze

      ROLE_PERMISSIONS = {
        "komsiluk_moderator" => %w(
          operations_read komsiluk_posts_read komsiluk_posts_moderate
        ),
        "debate_facilitator" => %w(
          operations_read
        ),
        "volunteer_reviewer" => %w(
          operations_read goodwill_dashboard_read volunteering_roster_read
          volunteering_opportunity_review volunteering_application_review volunteering_hours_review volunteering_partner_confirm
          volunteering_attendance_confirm volunteering_series_manage
        ),
        "community_reviewer" => %w(
          operations_read community_contributions_read community_project_review
          contribution_need_review contribution_offer_manage
        ),
        "report_triager" => %w(
          operations_read reports_mailbox_manage reports_read reports_update_status reports_internal_note
          reports_mark_duplicate reports_retry_forwarding
        ),
        "broadcast_operator" => %w(
          operations_read broadcast_preview broadcast_send_bell broadcast_send_viber
        ),
        "support_agent" => %w(
          operations_read operator_message_send citizen_lookup
        ),
        "general_support_agent" => %w(
          operations_read general_support_message_send citizen_lookup
        ),
        "analytics_viewer" => %w(
          operations_read analytics_read analytics_export
        ),
        "rewards_operator" => %w(
          operations_read goodwill_dashboard_read reward_fulfillment_update reward_fulfillment_export
          organization_spending_decide reward_fulfillment_checkin
        )
      }.freeze

      ADMIN_ONLY_PERMISSIONS = %w(
        operator_roles_manage operator_audit_read partner_profiles_manage
        partner_profiles_verify integrations_read integrations_manage privacy_retention_read
        privacy_retention_manage local_area_manage sistem48_settings_manage goodwill_settings_manage
        city_alerts_manage
        goodwill_manual_award goodwill_reverse_transaction match_request_create match_request_decide
        match_payout_record rewards_catalog_manage citizen_identity_correction citizen_ledger_read
        komsiluk_notification_policy_manage mi_bot_examples_read
      ).freeze

      ALL_PERMISSIONS = (ROLE_PERMISSIONS.values.flatten + ADMIN_ONLY_PERMISSIONS).uniq.freeze

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id"

      belongs_to :created_by,
                 class_name: "Decidim::User",
                 optional: true

      validates :role, presence: true, inclusion: { in: ROLES }
      validates :expires_at, presence: true
      validate :expires_at_is_future, on: :create
      validate :user_belongs_to_organization
      validate :creator_belongs_to_organization
      validates :area_scope, inclusion: { in: %w(all selected) }
      validate :valid_moderator_scope
      before_validation :normalize_komsiluk_ids
      after_commit :invalidate_recognition_cohort

      scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }
      scope :for_permission, lambda { |permission|
        roles = roles_for_permission(permission)
        roles.empty? ? none : where(role: roles)
      }

      def self.roles_for_permission(permission)
        permission = permission.to_s
        ROLE_PERMISSIONS.select { |_role, permissions| permissions.include?(permission) }.keys
      end

      def self.grantable_role_set?(roles, existing_roles: [])
        requested = Array(roles).map(&:to_s).uniq
        return false if requested.empty? || (requested - GRANTABLE_ROLES).any?

        effective = (requested + Array(existing_roles).map(&:to_s)).uniq
        requested.all? do |role|
          prerequisites = ROLE_PREREQUISITES[role]
          prerequisites.nil? || effective.intersect?(prerequisites.fetch(:any_of))
        end
      end

      def self.active_for(user, organization)
        return none if user.blank? || organization.blank?

        active.where(organization:, user:)
      end

      def self.operator?(user, organization)
        active_for(user, organization).exists?
      end

      def permissions
        ROLE_PERMISSIONS.fetch(role, [])
      end

      def covers_komsiluk?(area_id)
        area_scope == "all" || (area_scope == "selected" && Array(komsiluk_ids).include?(area_id.to_i))
      end

      def active?
        revoked_at.blank? && expires_at.present? && expires_at.future?
      end

      private

      def invalidate_recognition_cohort
        Decidim::Bih::PublicRecognition.invalidate_leaderboard_cache(user)
      end

      def normalize_komsiluk_ids
        self.komsiluk_ids = Array(komsiluk_ids).map(&:to_s).grep(/\A[1-9]\d*\z/).map(&:to_i).uniq.sort
        self.komsiluk_ids = [] if area_scope == "all"
      end

      def valid_moderator_scope
        return if area_scope == "all"

        if role != "komsiluk_moderator" || komsiluk_ids.blank? || organization.blank?
          errors.add(:area_scope, :invalid)
          return
        end
        valid_ids = LocalArea.komsiluci.where(organization:, id: komsiluk_ids).pluck(:id).sort
        errors.add(:komsiluk_ids, :invalid) unless valid_ids == komsiluk_ids
      end

      def expires_at_is_future
        return if expires_at.blank? || expires_at.future?

        errors.add(:expires_at, :future)
      end

      def user_belongs_to_organization
        return if user.blank? || organization.blank?
        return if user.organization == organization

        errors.add(:user, :invalid)
      end

      def creator_belongs_to_organization
        return if created_by.blank? || organization.blank?
        return if created_by.organization == organization

        errors.add(:created_by, :invalid)
      end
    end
  end
end

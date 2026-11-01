# frozen_string_literal: true

module Decidim
  module Bih
    # Publishes a pending non-cash need after LFBN review.
    class ApproveContributionNeed
      def self.call(need, reviewer:, profile_class: PartnerProfile, membership_class: PartnerMembership)
        new(need, reviewer:, profile_class:, membership_class:).call
      end

      def initialize(need, reviewer:, profile_class:, membership_class:)
        @need = need
        @reviewer = reviewer
        @profile_class = profile_class
        @membership_class = membership_class
      end

      def call
        status = guard_status
        return status if status

        result = :ok
        need.class.transaction do
          need.lock! if need.respond_to?(:lock!)
          need.partner_profile.lock! if need.partner_profile.respond_to?(:lock!)

          locked_status = locked_guard_status
          if locked_status
            result = locked_status
            next
          end

          need.update!(
            review_status: "approved",
            fulfillment_status: "open",
            reviewer:,
            reviewed_at: Time.current,
            published_at: Time.current,
            closed_at: nil,
            rejection_reason: nil
          )
        end
        notify_author("need_approved") if result == :ok
        result
      rescue ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError
        :invalid
      end

      private

      attr_reader :need, :reviewer, :profile_class, :membership_class

      def guard_status
        return :missing if need.blank?
        return :already if need.approved?
        return :invalid unless need.pending_review?
        return :invalid unless partner_profile_publicly_eligible?
        return :invalid unless volunteer_manager_available?

        :invalid unless reviewer.present? && reviewer.organization == need.organization
      end

      def locked_guard_status
        return :already if need.approved?
        return :invalid unless need.pending_review?
        return :invalid unless partner_profile_publicly_eligible?

        :invalid unless volunteer_manager_available?
      end

      def partner_profile_publicly_eligible?
        profile = need.partner_profile
        return false unless profile

        profile_class.publicly_visible.exists?(
          id: profile.id,
          decidim_organization_id: need.organization.id
        )
      end

      def volunteer_manager_available?
        membership_class.accepted.exists?(
          partner_profile: need.partner_profile,
          role: membership_class::VOLUNTEER_ROLES
        )
      end

      def notify_author(transition)
        CommunityContributionNotifications.publish(
          transition:,
          item: need.title,
          affected_users: [need.author],
          path: CommunityContributionNotifications.public_path("volontiranje?tab=potrebe")
        )
      rescue StandardError => e
        Rails.logger&.error("[ApproveContributionNeed] notification failed: #{e.class}") if Rails.respond_to?(:logger)
        nil
      end
    end
  end
end

# frozen_string_literal: true

require "bigdecimal"

module Decidim
  module Bih
    # Creates one active personal or partner-profile offer against a public need.
    class CreateContributionOffer
      def self.call(
        need:,
        contributor:,
        quantity:,
        partner_profile: nil,
        **dependencies
      )
        new(need:, contributor:, quantity:, partner_profile:, dependencies:).call
      end

      def initialize(need:, contributor:, quantity:, partner_profile:, dependencies:)
        @need = need
        @contributor = contributor
        @quantity = quantity
        @partner_profile = partner_profile
        @offer_class = dependencies.fetch(:offer_class) { ContributionOffer }
        @profile_class = dependencies.fetch(:profile_class) { PartnerProfile }
      end

      def call
        status = guard_status
        return [status, nil] if status

        result = nil
        offer_class.transaction do
          need.lock! if need.respond_to?(:lock!)
          lock_partner_profiles!
          result = create_locked
        end
        notify_receiving_managers if result.first == :ok
        result
      rescue ActiveRecord::RecordNotUnique
        [:already, active_offer]
      end

      private

      attr_reader :need, :contributor, :quantity, :partner_profile, :offer_class, :profile_class

      def guard_status
        return :missing if need.blank?
        return :forbidden unless contributor.present? && contributor.organization == need.organization
        return :invalid unless need.approved? && need.open?
        return :invalid unless receiving_profile_publicly_eligible?

        :forbidden unless may_represent_partner_profile?
      end

      def create_locked
        return [:invalid, nil] unless need.approved? && need.open?
        return [:invalid, nil] unless receiving_profile_publicly_eligible?
        return [:forbidden, nil] unless may_represent_partner_profile?

        existing = active_offer
        return [:already, existing] if existing
        return [:invalid, nil] unless requested_quantity.positive?
        return [:invalid, nil] if requested_quantity > need.remaining_quantity

        offer = offer_class.new(
          organization: need.organization,
          contribution_need: need,
          contributor:,
          partner_profile:,
          quantity: requested_quantity,
          status: "offered"
        )
        return [:invalid, offer] unless offer.save

        [:ok, offer]
      end

      def requested_quantity
        @requested_quantity ||= BigDecimal(quantity.to_s)
      rescue ArgumentError
        BigDecimal("0")
      end

      def may_represent_partner_profile?
        return true if partner_profile.blank?
        return false unless partner_profile.organization == need.organization
        return false unless profile_class.volunteer_opportunity_eligible.exists?(
          id: partner_profile.id,
          decidim_organization_id: need.organization.id
        )

        membership = partner_profile.memberships.accepted.find_by(user: contributor)
        membership&.volunteer_manager? || false
      end

      def receiving_profile_publicly_eligible?
        profile_class.publicly_visible.exists?(
          id: need.partner_profile.id,
          decidim_organization_id: need.organization.id
        )
      end

      def lock_partner_profiles!
        need.partner_profile.lock! if need.partner_profile.respond_to?(:lock!)
        return unless partner_profile.present? && partner_profile != need.partner_profile

        partner_profile.lock! if partner_profile.respond_to?(:lock!)
      end

      def active_offer
        scope = offer_class.active.where(contribution_need: need)
        if partner_profile.present?
          scope.find_by(partner_profile:)
        else
          scope.find_by(partner_profile_id: nil, contributor:)
        end
      end

      def notify_receiving_managers
        users = need.partner_profile.memberships
                    .accepted
                    .where(role: Decidim::Bih::PartnerMembership::VOLUNTEER_ROLES)
                    .includes(:user)
                    .map(&:user)
        CommunityContributionNotifications.publish(
          transition: "offer_created",
          item: need.title,
          affected_users: users,
          path: CommunityContributionNotifications.public_path("volontiranje?tab=potrebe")
        )
      rescue StandardError => e
        Rails.logger&.error("[CreateContributionOffer] offer notification failed: #{e.class}") if Rails.respond_to?(:logger)
        nil
      end
    end
  end
end

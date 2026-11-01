# frozen_string_literal: true

module Decidim
  module Bih
    # Enforces the offer state machine and actor boundaries. Receiving-partner
    # coordinators accept/decline/confirm; contributors deliver/withdraw; LFBN
    # operators recognize confirmed help. Only recognized personal help earns
    # citizen points, exactly once.
    class ManageContributionOffer
      ACTIONS = %w(accept decline withdraw mark_delivered confirm recognize).freeze

      def self.call(
        offer:,
        actor:,
        action:,
        reason: nil,
        **dependencies
      )
        new(offer:, actor:, action:, reason:, dependencies:).call
      end

      def initialize(offer:, actor:, action:, reason:, dependencies:)
        @offer = offer
        @actor = actor
        @action = action.to_s
        @reason = reason.to_s.strip
        @offer_class = dependencies.fetch(:offer_class) { ContributionOffer }
        @profile_class = dependencies.fetch(:profile_class) { PartnerProfile }
        @operator_role_class = dependencies.fetch(:operator_role_class) { OperatorRole }
        @award_dispatch = dependencies.fetch(:award_dispatch) { Decidim::Bih::Goodwill::AwardDispatch }
      end

      def call
        return :missing if offer.blank?
        return :invalid unless ACTIONS.include?(action)
        return :forbidden unless actor.present? && actor.organization == offer.organization

        result = nil
        offer_class.transaction do
          lock_workflow_records!
          result = authorized? ? transition : :forbidden
        end
        notify_transition if result == :ok
        result
      rescue ActiveRecord::RecordInvalid
        :invalid
      end

      private

      attr_reader :offer, :actor, :action, :reason, :offer_class, :profile_class, :operator_role_class, :award_dispatch

      def lock_workflow_records!
        offer.contribution_need.lock! if offer.contribution_need.respond_to?(:lock!)
        receiving_profile = offer.contribution_need.partner_profile
        receiving_profile.lock! if receiving_profile.respond_to?(:lock!)
        offering_profile = offer.partner_profile
        lock_offering_profile = offering_profile.present? &&
                                offering_profile != receiving_profile &&
                                offering_profile.respond_to?(:lock!)
        offering_profile.lock! if lock_offering_profile
        offer.lock! if offer.respond_to?(:lock!)
      end

      def authorized?
        case action
        when "accept", "decline", "confirm"
          offer.contribution_need.managed_by?(actor)
        when "withdraw", "mark_delivered"
          contributor_actor?
        when "recognize"
          recognition_operator?
        else
          false
        end
      end

      def contributor_actor?
        return offer.contributor == actor if offer.partner_profile.blank?

        membership = offer.partner_profile.memberships.accepted.find_by(user: actor)
        membership&.volunteer_manager? || false
      end

      def recognition_operator?
        return true if actor.respond_to?(:admin?) && actor.admin?

        operator_role_class.active_for(actor, offer.organization)
                           .for_permission("contribution_offer_manage")
                           .exists?
      end

      def transition
        case action
        when "accept" then accept
        when "decline" then decline
        when "withdraw" then withdraw
        when "mark_delivered" then mark_delivered
        when "confirm" then confirm
        when "recognize" then recognize
        end
      end

      def accept
        return :already if offer.accepted? || offer.delivered? || offer.confirmed?
        return :invalid unless offer.offered?

        need = offer.contribution_need
        return :invalid unless need.approved? && need.open?
        return :invalid unless receiving_profile_publicly_eligible?
        return :invalid if offer.quantity > need.remaining_quantity(excluding: offer)

        offer.update!(status: "accepted", accepted_by: actor, accepted_at: Time.current, decline_reason: nil)
        :ok
      end

      def receiving_profile_publicly_eligible?
        profile_class.publicly_visible.exists?(
          id: offer.contribution_need.partner_profile.id,
          decidim_organization_id: offer.organization.id
        )
      end

      def decline
        return :already if offer.declined?
        return :invalid unless offer.offered? || offer.accepted?
        return :invalid if reason.length > offer.class::MAX_DECLINE_REASON_LENGTH

        offer.update!(status: "declined", declined_by: actor, declined_at: Time.current, decline_reason: reason.presence)
        :ok
      end

      def withdraw
        return :already if offer.withdrawn?
        return :invalid unless offer.offered? || offer.accepted?

        offer.update!(status: "withdrawn", withdrawn_at: Time.current)
        :ok
      end

      def mark_delivered
        return :already if offer.delivered? || offer.confirmed?
        return :invalid unless offer.accepted?

        offer.update!(status: "delivered", delivered_at: Time.current)
        :ok
      end

      def confirm
        return :already if offer.confirmed?
        return :invalid unless offer.delivered?

        offer.update!(status: "confirmed", confirmed_by: actor, confirmed_at: Time.current)
        fulfill_need_if_complete!
        :ok
      end

      def recognize
        return :already if offer.recognized?
        return :invalid unless offer.confirmed?

        offer.update!(recognized_by: actor, recognized_at: Time.current)
        award_dispatch.contribution_offer_recognized(offer, reviewer: actor)
        :ok
      end

      def fulfill_need_if_complete!
        need = offer.contribution_need
        return unless need.open? && need.confirmed_quantity >= need.quantity

        need.update!(fulfillment_status: "fulfilled", closed_at: Time.current)
      end

      def notify_transition
        recipients = case action
                     when "mark_delivered" then receiving_managers
                     when "accept", "decline", "confirm", "recognize" then [offer.contributor]
                     else []
                     end
        CommunityContributionNotifications.publish(
          transition: "offer_#{action}",
          item: offer.contribution_need.title,
          affected_users: recipients,
          path: CommunityContributionNotifications.public_path("volontiranje?tab=potrebe")
        )
      rescue StandardError => e
        Rails.logger&.error("[ManageContributionOffer] #{action} notification failed: #{e.class}") if Rails.respond_to?(:logger)
        nil
      end

      def receiving_managers
        offer.contribution_need.partner_profile.memberships
             .accepted
             .where(role: Decidim::Bih::PartnerMembership::VOLUNTEER_ROLES)
             .includes(:user)
             .map(&:user)
      end
    end
  end
end

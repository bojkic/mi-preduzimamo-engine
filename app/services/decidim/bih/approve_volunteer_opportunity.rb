# frozen_string_literal: true

module Decidim
  module Bih
    # Publishes a pending volunteer opportunity after admin review and awards
    # the proposer once. The award is idempotent on the opportunity id.
    class ApproveVolunteerOpportunity < ReviewDecision
      def self.call(opportunity, reviewer:, confirm_partner: false, notify: true)
        new(opportunity, reviewer:, confirm_partner:, notify:).call
      end

      def initialize(opportunity, reviewer:, confirm_partner: false, notify: true)
        super()
        @opportunity = opportunity
        @reviewer = reviewer
        @confirm_partner = confirm_partner == true
        @notify_author = notify == true
      end

      private

      attr_reader :opportunity, :reviewer, :confirm_partner

      def guards
        [
          [:missing, -> { opportunity.blank? }],
          [:already, -> { opportunity.approved? }],
          [:invalid, -> { !opportunity.pending_review? }],
          [:invalid, -> { reviewer.blank? || reviewer.organization != opportunity.organization }],
          [:invalid, -> { !partner_profile_currently_eligible? }],
          [:invalid, -> { partner_agreement_required? && !confirm_partner }]
        ]
      end

      def transaction_model
        VolunteerOpportunity
      end

      def review_record
        opportunity
      end

      def lock_related_records
        profile = opportunity.partner_profile
        profile.lock! if profile.respond_to?(:lock!)
      end

      def partner_profile_currently_eligible?
        profile = opportunity.partner_profile
        profile.blank? || profile.volunteer_opportunity_eligible?
      end

      def partner_agreement_required?
        opportunity.respond_to?(:partner_name) && opportunity.partner_name.present? &&
          !opportunity.partner_confirmed?
      end

      def perform
        values = {
          active: true,
          review_status: "approved",
          reviewer:,
          reviewed_at: Time.current,
          rejection_reason: nil
        }
        if confirm_partner && partner_agreement_required?
          values[:partner_confirmed_at] = Time.current
          values[:partner_confirmer] = reviewer
        end
        opportunity.update!(values)
        award_author
      end

      def notify
        return unless @notify_author

        VolunteerNotifications.publish(
          user: opportunity.author,
          kind: :opportunity,
          status: :approved,
          title: opportunity.title
        )
      end

      def award_author
        Decidim::Bih::Goodwill::AwardDispatch.volunteer_opportunity_approved(opportunity, reviewer:)
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Privacy-safe, derived public recognition for one partner profile. The
    # result contains aggregate counts/totals only and never employee/member
    # names, contacts or inferred company cash donations.
    class PartnerImpactSummary
      Result = Data.define(
        :approved_projects_count,
        :approved_needs_count,
        :fulfilled_needs_count,
        :confirmed_offers_count,
        :hosted_volunteer_opportunities_count,
        :approved_volunteer_hours,
        :distinct_volunteer_participants_count,
        :recognition_labels
      )

      def self.call(partner_profile:, **dependencies)
        new(partner_profile:, **dependencies).call
      end

      def initialize(
        partner_profile:,
        **dependencies
      )
        @partner_profile = partner_profile
        @submission_class = dependencies.fetch(:submission_class) { PartnerProjectSubmission }
        @need_class = dependencies.fetch(:need_class) { ContributionNeed }
        @offer_class = dependencies.fetch(:offer_class) { ContributionOffer }
        @opportunity_class = dependencies.fetch(:opportunity_class) { VolunteerOpportunity }
        @log_class = dependencies.fetch(:log_class) { VolunteerLog }
      end

      def call
        projects_count = submission_class.approved.where(partner_profile:).count
        needs = need_class.approved.where(partner_profile:)
        approved_needs_count = needs.count
        fulfilled_needs_count = needs.fulfilled.count
        # Keep the public result field name for compatibility, but count only
        # beneficiary-confirmed offers that LFBN has subsequently recognized.
        confirmed_offers_count = offer_class.recognized.where(partner_profile:).count
        # Impact is lifetime approved history, not current discovery. Completed
        # or cancelled approved shifts and their verified hours remain part of
        # the partner's durable contribution record.
        opportunities = opportunity_class.where(
          organization: partner_profile.organization,
          partner_profile:,
          review_status: "approved"
        )
        hosted_opportunities_count = opportunities.count
        logs = log_class.approved.where(opportunity: opportunities)

        Result.new(
          approved_projects_count: projects_count,
          approved_needs_count:,
          fulfilled_needs_count:,
          confirmed_offers_count:,
          hosted_volunteer_opportunities_count: hosted_opportunities_count,
          approved_volunteer_hours: logs.sum(:hours),
          distinct_volunteer_participants_count: logs.distinct.count(:decidim_user_id),
          recognition_labels: recognition_labels(
            projects_count:,
            fulfilled_needs_count:,
            confirmed_offers_count:,
            hosted_opportunities_count:
          ).freeze
        ).freeze
      end

      private

      attr_reader :partner_profile, :submission_class, :need_class, :offer_class, :opportunity_class, :log_class

      def recognition_labels(projects_count:, fulfilled_needs_count:, confirmed_offers_count:, hosted_opportunities_count:)
        labels = []
        labels << :project_initiator if projects_count.positive?
        labels << :community_partner if fulfilled_needs_count.positive? || confirmed_offers_count.positive?
        labels << :volunteer_host if hosted_opportunities_count.positive?
        completed_signals = projects_count + fulfilled_needs_count + confirmed_offers_count + hosted_opportunities_count
        labels << :repeat_partner if completed_signals >= 2
        labels
      end
    end
  end
end

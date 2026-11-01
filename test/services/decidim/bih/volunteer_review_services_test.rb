# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time"
require_relative "../../../../app/services/decidim/bih/review_decision"
require_relative "../../../../app/services/decidim/bih/approve_volunteer_opportunity"
require_relative "../../../../app/services/decidim/bih/reject_volunteer_opportunity"
require_relative "../../../../app/services/decidim/bih/verify_volunteer_log"
require_relative "../../../../app/services/decidim/bih/reject_volunteer_log"

module Decidim
  module Bih
    class VolunteerReviewServicesTest < Minitest::Test
      Person = Struct.new(:id, :organization, keyword_init: true)
      PartnerProfile = Struct.new(:eligible, keyword_init: true) do
        attr_accessor :on_lock

        def volunteer_opportunity_eligible?
          eligible
        end

        def lock!
          on_lock&.call
          self
        end
      end
      Opportunity = Struct.new(:id, :title, :author, :organization, :partner_profile, :partner_name, :partner_confirmed_at, :state, keyword_init: true) do
        attr_accessor :on_lock
        attr_reader :updates

        def initialize(*)
          super
          @updates = []
        end

        def partner_confirmed?
          partner_confirmed_at.present?
        end

        def approved?
          state == :approved
        end

        def rejected?
          state == :rejected
        end

        def pending_review?
          state == :pending
        end

        def update!(attributes)
          @updates << attributes
        end

        def lock!
          on_lock&.call
          self
        end
      end

      VolunteerLogRecord = Struct.new(:id, :hours, :user, :opportunity, :state, keyword_init: true) do
        attr_accessor :on_lock
        attr_reader :updates

        def initialize(*)
          super
          @updates = []
        end

        def approved?
          state == :approved
        end

        def pending?
          state == :pending
        end

        def update!(attributes)
          @updates << attributes
        end

        def lock!
          on_lock&.call
          self
        end
      end

      class TransactionModel
        class << self
          attr_reader :events

          def reset!
            @events = []
          end

          def transaction
            @events << :begin
            yield
          ensure
            @events << :end
          end
        end
      end

      class AwardDispatch
        class << self
          attr_reader :awards

          def reset!
            @awards = []
            @points_per_hour = 100
          end

          attr_accessor :points_per_hour
        end

        def self.volunteer_opportunity_approved(opportunity, reviewer:)
          return nil unless opportunity.author

          awards << { opportunity:, reviewer: }
        end

        def self.volunteer_log_verified(log)
          awards << { log:, points: log.hours * points_per_hour }
        end
      end

      class Notifications
        class << self
          attr_reader :payloads

          def reset!
            @payloads = []
          end

          def publish(payload)
            @payloads << payload
          end
        end
      end

      class VolunteerOrgBonus
        class << self
          attr_reader :logs

          def reset!
            @logs = []
          end

          def call(log)
            logs << log
          end
        end
      end

      def setup
        @organization = Object.new
        @reviewer = Person.new(id: 9, organization: @organization)
        @author = Person.new(id: 10, organization: @organization)
        @volunteer = Person.new(id: 11, organization: @organization)
        @opportunity = Opportunity.new(
          id: 42,
          title: "Uredi park",
          author: @author,
          organization: @organization,
          state: :pending
        )
        TransactionModel.reset!
        AwardDispatch.reset!
        Notifications.reset!
        VolunteerOrgBonus.reset!
      end

      def test_approve_opportunity_updates_awards_and_notifies_author
        result = with_review_collaborators do
          ApproveVolunteerOpportunity.call(@opportunity, reviewer: @reviewer)
        end

        assert_equal :ok, result
        assert_equal [:begin, :end], TransactionModel.events
        assert_equal 1, @opportunity.updates.size
        update = @opportunity.updates.first
        assert_equal true, update[:active]
        assert_equal "approved", update[:review_status]
        assert_equal @reviewer, update[:reviewer]
        assert_respond_to update[:reviewed_at], :to_time
        assert_nil update[:rejection_reason]
        assert_equal(
          [{ opportunity: @opportunity, reviewer: @reviewer }],
          AwardDispatch.awards
        )
        assert_equal(
          [{ user: @author, kind: :opportunity, status: :approved, title: "Uredi park" }],
          Notifications.payloads
        )
      end

      def test_approve_partner_opportunity_requires_explicit_agreement_and_records_its_actor
        @opportunity.partner_name = "Partner"

        without_agreement = with_review_collaborators do
          ApproveVolunteerOpportunity.call(@opportunity, reviewer: @reviewer)
        end
        assert_equal :invalid, without_agreement
        assert_empty @opportunity.updates
        assert_empty AwardDispatch.awards

        with_agreement = with_review_collaborators do
          ApproveVolunteerOpportunity.call(@opportunity, reviewer: @reviewer, confirm_partner: true)
        end
        assert_equal :ok, with_agreement
        assert_equal @reviewer, @opportunity.updates.first[:partner_confirmer]
        assert_respond_to @opportunity.updates.first[:partner_confirmed_at], :to_time
      end

      def test_approve_opportunity_short_circuits_when_already_approved
        @opportunity.state = :approved

        result = with_review_collaborators do
          ApproveVolunteerOpportunity.call(@opportunity, reviewer: @reviewer)
        end

        assert_equal :already, result
        assert_empty @opportunity.updates
        assert_empty AwardDispatch.awards
        assert_empty Notifications.payloads
        assert_empty TransactionModel.events
      end

      def test_approve_opportunity_rechecks_state_and_profile_eligibility_under_locks
        profile = PartnerProfile.new(eligible: true)
        @opportunity.partner_profile = profile
        @opportunity.on_lock = -> { profile.eligible = false }

        result = with_review_collaborators do
          ApproveVolunteerOpportunity.call(@opportunity, reviewer: @reviewer)
        end

        assert_equal :invalid, result
        assert_equal [:begin, :end], TransactionModel.events
        assert_empty @opportunity.updates
        assert_empty AwardDispatch.awards
        assert_empty Notifications.payloads
      end

      def test_verify_log_rejects_undated_claim_before_any_transition
        log = VolunteerLogRecord.new(
          id: 77,
          hours: 2,
          user: @volunteer,
          opportunity: @opportunity,
          state: :pending
        )
        result = with_review_collaborators do
          VerifyVolunteerLog.call(log, verifier: @reviewer)
        end

        assert_equal :invalid, result
        assert_empty TransactionModel.events
        assert_empty log.updates
        assert_empty AwardDispatch.awards
        assert_empty Notifications.payloads
      end

      def test_approve_opportunity_with_no_author_does_not_award_but_still_uses_notification_wrapper
        @opportunity.author = nil

        result = with_review_collaborators do
          ApproveVolunteerOpportunity.call(@opportunity, reviewer: @reviewer)
        end

        assert_equal :ok, result
        assert_empty AwardDispatch.awards
        assert_equal(
          [{ user: nil, kind: :opportunity, status: :approved, title: "Uredi park" }],
          Notifications.payloads
        )
      end

      def test_reject_opportunity_guards_missing_already_invalid_and_blank_reason
        rejected = Opportunity.new(id: 43, title: "Stara", author: @author, state: :rejected)
        approved = Opportunity.new(id: 44, title: "Aktivna", author: @author, state: :approved)

        with_review_collaborators do
          assert_equal :missing, RejectVolunteerOpportunity.call(nil, reviewer: @reviewer, reason: "Ne")
          assert_equal :already, RejectVolunteerOpportunity.call(rejected, reviewer: @reviewer, reason: "Ne")
          assert_equal :invalid, RejectVolunteerOpportunity.call(approved, reviewer: @reviewer, reason: "Ne")
          assert_equal :invalid, RejectVolunteerOpportunity.call(@opportunity, reviewer: @reviewer, reason: "  ")
        end

        assert_empty rejected.updates
        assert_empty approved.updates
        assert_empty @opportunity.updates
        assert_empty Notifications.payloads
      end

      def test_reject_opportunity_updates_with_stripped_reason_and_notifies
        result = with_review_collaborators do
          RejectVolunteerOpportunity.call(@opportunity, reviewer: @reviewer, reason: "  Nije dovoljno jasno  ")
        end

        assert_equal :ok, result
        update = @opportunity.updates.first
        assert_equal false, update[:active]
        assert_equal "rejected", update[:review_status]
        assert_equal @reviewer, update[:reviewer]
        assert_respond_to update[:reviewed_at], :to_time
        assert_equal "Nije dovoljno jasno", update[:rejection_reason]
        assert_empty AwardDispatch.awards
        assert_equal(
          [
            {
              user: @author,
              kind: :opportunity,
              status: :rejected,
              title: "Uredi park",
              reason: "Nije dovoljno jasno"
            }
          ],
          Notifications.payloads
        )
      end

      def test_verify_log_does_not_pay_hours_from_an_rsvp_without_a_work_interval
        log = VolunteerLogRecord.new(id: 77, hours: 2.5, user: @volunteer, opportunity: @opportunity, state: :pending)
        AwardDispatch.points_per_hour = 40

        result = with_review_collaborators do
          VerifyVolunteerLog.call(log, verifier: @reviewer)
        end

        assert_equal :invalid, result
        assert_empty TransactionModel.events
        assert_empty log.updates
        assert_empty AwardDispatch.awards
        assert_empty VolunteerOrgBonus.logs
        assert_empty Notifications.payloads
      end

      def test_verify_log_guards_missing_already_and_invalid_states
        approved = VolunteerLogRecord.new(id: 1, hours: 1, user: @volunteer, opportunity: @opportunity, state: :approved)
        rejected = VolunteerLogRecord.new(id: 2, hours: 1, user: @volunteer, opportunity: @opportunity, state: :rejected)

        with_review_collaborators do
          assert_equal :missing, VerifyVolunteerLog.call(nil, verifier: @reviewer)
          assert_equal :already, VerifyVolunteerLog.call(approved, verifier: @reviewer)
          assert_equal :invalid, VerifyVolunteerLog.call(rejected, verifier: @reviewer)
        end

        assert_empty AwardDispatch.awards
        assert_empty Notifications.payloads
        assert_empty TransactionModel.events
      end

      def test_reject_log_updates_with_stripped_reason_and_notifies_without_ledger_award
        log = VolunteerLogRecord.new(id: 88, hours: 3, user: @volunteer, opportunity: @opportunity, state: :pending)

        result = with_review_collaborators do
          RejectVolunteerLog.call(log, verifier: @reviewer, reason: "  Nema potvrde  ")
        end

        assert_equal :ok, result
        update = log.updates.first
        assert_equal "rejected", update[:status]
        assert_equal @reviewer, update[:verifier]
        assert_respond_to update[:verified_at], :to_time
        assert_equal "Nema potvrde", update[:rejection_reason]
        assert_empty AwardDispatch.awards
        assert_equal(
          [
            {
              user: @volunteer,
              kind: :log,
              status: :rejected,
              title: "Uredi park",
              reason: "Nema potvrde"
            }
          ],
          Notifications.payloads
        )
      end

      def test_reject_log_guards_missing_non_pending_and_blank_reason
        approved = VolunteerLogRecord.new(id: 1, hours: 1, user: @volunteer, opportunity: @opportunity, state: :approved)

        with_review_collaborators do
          assert_equal :missing, RejectVolunteerLog.call(nil, verifier: @reviewer, reason: "Ne")
          assert_equal :already, RejectVolunteerLog.call(approved, verifier: @reviewer, reason: "Ne")
          assert_equal :invalid, RejectVolunteerLog.call(
            VolunteerLogRecord.new(id: 2, hours: 1, user: @volunteer, opportunity: @opportunity, state: :pending),
            verifier: @reviewer,
            reason: " "
          )
        end

        assert_empty AwardDispatch.awards
        assert_empty Notifications.payloads
        assert_empty TransactionModel.events
      end

      private

      def with_review_collaborators(&)
        with_constant(Decidim::Bih, :VolunteerOpportunity, TransactionModel) do
          with_constant(Decidim::Bih, :VolunteerLog, TransactionModel) do
            with_constant(Decidim::Bih, :VolunteerNotifications, Notifications) do
              ensure_goodwill_namespace do |goodwill|
                with_constant(goodwill, :AwardDispatch, AwardDispatch) do
                  with_constant(goodwill, :VolunteerOrgBonus, VolunteerOrgBonus, &)
                end
              end
            end
          end
        end
      end

      def ensure_goodwill_namespace
        old_defined = Decidim::Bih.const_defined?(:Goodwill, false)
        old_value = Decidim::Bih.const_get(:Goodwill, false) if old_defined
        Decidim::Bih.send(:remove_const, :Goodwill) if old_defined
        goodwill = Module.new
        Decidim::Bih.const_set(:Goodwill, goodwill)
        yield goodwill
      ensure
        Decidim::Bih.send(:remove_const, :Goodwill) if Decidim::Bih.const_defined?(:Goodwill, false)
        Decidim::Bih.const_set(:Goodwill, old_value) if old_defined
      end

      def with_constant(parent, name, value)
        old_defined = parent.const_defined?(name, false)
        old_value = parent.const_get(name, false) if old_defined
        parent.send(:remove_const, name) if old_defined
        parent.const_set(name, value)
        yield
      ensure
        parent.send(:remove_const, name) if parent.const_defined?(name, false)
        parent.const_set(name, old_value) if old_defined
      end
    end
  end
end

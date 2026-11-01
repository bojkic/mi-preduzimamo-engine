# frozen_string_literal: true

require "test_helper"
require "active_record"
require "active_support/core_ext/object/blank"
require "active_support/time"
require_relative "../../../../app/services/decidim/bih/community_contribution_notifications"
require_relative "../../../../app/services/decidim/bih/submit_partner_project_submission"
require_relative "../../../../app/services/decidim/bih/approve_partner_project_submission"
require_relative "../../../../app/services/decidim/bih/reject_partner_project_submission"
require_relative "../../../../app/services/decidim/bih/request_partner_project_changes"
require_relative "../../../../app/services/decidim/bih/approve_contribution_need"
require_relative "../../../../app/services/decidim/bih/reject_contribution_need"
require_relative "../../../../app/services/decidim/bih/cancel_contribution_need"
require_relative "../../../../app/services/decidim/bih/create_contribution_offer"
require_relative "../../../../app/services/decidim/bih/manage_contribution_offer"

module Decidim
  module Bih
    class CommunityContributionServicesTest < Minitest::Test
      Organization = Struct.new(:id, :available_locales, :default_locale, keyword_init: true)
      Actor = Struct.new(:id, :organization, :admin, keyword_init: true) do
        def admin?
          admin
        end
      end
      Profile = Struct.new(:id, :verified, :on_lock, keyword_init: true) do
        def verified?
          verified
        end

        def lock!
          on_lock&.call
          self
        end
      end

      class MembershipClass
        VOLUNTEER_ROLES = %w(owner manager volunteer_coordinator).freeze

        class << self
          attr_accessor :available

          def accepted = self

          def exists?(**) = available
        end
      end

      class Submission
        MAX_REJECTION_REASON_LENGTH = 1_000

        class << self
          attr_reader :transactions

          def reset!
            @transactions = 0
          end

          def transaction
            @transactions += 1
            yield
          end
        end

        attr_accessor :review_status
        attr_reader :organization, :partner_profile, :representative, :title, :description, :budget_amount, :address,
                    :updates

        def initialize(organization:, representative:, review_status: "draft", profile_verified: true)
          @organization = organization
          @partner_profile = Profile.new(id: 41, verified: profile_verified)
          @representative = representative
          @review_status = review_status
          @title = "Uredimo park"
          @description = "Sadnja <script>alert(1)</script>\nklupa"
          @budget_amount = 4_200
          @address = "Gradski park"
          @updates = []
        end

        def draft? = review_status == "draft"

        def submitted? = review_status == "submitted"

        def changes_requested? = review_status == "changes_requested"

        def approved? = review_status == "approved"

        def rejected? = review_status == "rejected"

        def represented_by_content_manager?(actor) = [5, 7].include?(actor.id)

        def lock! = self

        def update!(attributes)
          @updates << attributes
          @review_status = attributes[:review_status] if attributes.has_key?(:review_status)
          @representative = attributes[:representative] if attributes.has_key?(:representative)
        end
      end

      class Space
        attr_reader :organization
        attr_writer :published

        def initialize(organization)
          @organization = organization
          @published = false
        end

        def published? = @published

        def visible? = true
      end

      class Component
        def initialize(organization)
          @participatory_space = Space.new(organization)
        end

        attr_reader :participatory_space

        def published? = true
      end

      class ProjectRelation
        attr_reader :records

        def initialize
          @records = []
        end

        def sum(column)
          records.sum { |record| record.fetch(column) }
        end
      end

      class Budget
        attr_reader :id, :organization, :component, :projects

        def initialize(id:, organization:)
          @id = id
          @organization = organization
          @component = Component.new(organization)
          @projects = ProjectRelation.new
        end

        def visible? = true

        def lock! = self
      end

      class BudgetClass
        class << self
          attr_accessor :record
        end

        def self.find_by(id:)
          record if record&.id == id
        end
      end

      class SettingClass
        class << self
          attr_accessor :value
        end

        def self.namespace_for(_organization, namespace)
          raise "wrong namespace" unless namespace == "community_projects"

          value.nil? ? {} : { "budget_id" => value }
        end
      end

      class ProjectClass
        def self.domain_test_double? = true
      end

      class LinkClass
        CAMPAIGN_KEY_PATTERN = /\A[a-z0-9][a-z0-9_-]*\z/
        MAX_CAMPAIGN_KEY_LENGTH = 100

        class << self
          attr_reader :created

          def reset!
            @created = []
          end

          def create!(attributes)
            @created << attributes
          end
        end
      end

      class Traceability
        attr_reader :creates, :updates

        def initialize
          @creates = []
          @updates = []
        end

        def create!(klass, actor, attributes, extra)
          @creates << { klass:, actor:, attributes:, extra: }
          project = attributes.slice(:budget_amount)
          attributes.fetch(:budget).projects.records << project
          project
        end

        def update!(record, actor, attributes, extra)
          @updates << { record:, actor:, attributes:, extra: }
        end
      end

      class Need
        MAX_REJECTION_REASON_LENGTH = 1_000

        def self.transaction
          yield
        end

        attr_accessor :review_status, :fulfillment_status, :confirmed_quantity, :remaining_quantity_value,
                      :close_on_lock, :offers, :stale_on_update
        attr_reader :organization, :partner_profile, :quantity, :updates, :lock_count

        def initialize(
          organization:,
          review_status: "pending",
          fulfillment_status: "open",
          quantity: 2,
          profile_verified: true
        )
          @organization = organization
          @partner_profile = Profile.new(id: 42, verified: profile_verified)
          @review_status = review_status
          @fulfillment_status = fulfillment_status
          @quantity = quantity
          @confirmed_quantity = 0
          @remaining_quantity_value = quantity
          @close_on_lock = false
          @lock_count = 0
          @updates = []
          @offers = OfferCollection.new([])
          @stale_on_update = false
        end

        def pending_review? = review_status == "pending"

        def approved? = review_status == "approved"

        def rejected? = review_status == "rejected"

        def open? = fulfillment_status == "open"

        def cancelled? = fulfillment_status == "cancelled"

        def managed_by?(actor) = actor.organization == organization && actor.id == 7

        def remaining_quantity(*) = remaining_quantity_value

        def lock!
          @lock_count += 1
          @fulfillment_status = "fulfilled" if close_on_lock
          self
        end

        def update!(attributes)
          raise ActiveRecord::StaleObjectError.new(self, "update") if stale_on_update

          @updates << attributes
          @review_status = attributes[:review_status] if attributes.has_key?(:review_status)
          @fulfillment_status = attributes[:fulfillment_status] if attributes.has_key?(:fulfillment_status)
        end
      end

      class Offer
        MAX_DECLINE_REASON_LENGTH = 1_000

        attr_accessor :status, :recognized_at, :partner_profile
        attr_reader :id, :organization, :contribution_need, :contributor, :quantity, :updates

        def initialize(id:, organization:, contribution_need:, contributor:, **attributes)
          @id = id
          @organization = organization
          @contribution_need = contribution_need
          @contributor = contributor
          @quantity = attributes.fetch(:quantity, 2)
          @status = attributes.fetch(:status, "offered")
          @partner_profile = nil
          @recognized_at = nil
          @updates = []
        end

        def offered? = status == "offered"

        def accepted? = status == "accepted"

        def declined? = status == "declined"

        def withdrawn? = status == "withdrawn"

        def delivered? = status == "delivered"

        def confirmed? = status == "confirmed"

        def recognized? = !recognized_at.nil?

        def lock! = self

        def update!(attributes)
          @updates << attributes
          @status = attributes[:status] if attributes.has_key?(:status)
          @recognized_at = attributes[:recognized_at] if attributes.has_key?(:recognized_at)
          contribution_need.confirmed_quantity = quantity_after_confirmation if status == "confirmed"
        end

        private

        def quantity_after_confirmation
          contribution_need.quantity
        end
      end

      class OfferCollection
        attr_reader :records, :lock_count

        def initialize(records)
          @records = records
          @lock_count = 0
        end

        def lock
          @lock_count += 1
          self
        end

        def to_a = records
      end

      class OfferClass
        def self.transaction
          yield
        end
      end

      class NoMemberships
        def accepted = self

        def find_by(*) = nil
      end

      class PartnerProfile
        EligibilityScope = Struct.new(:eligible) do
          def exists?(**) = eligible
        end

        class << self
          attr_accessor :publicly_eligible, :volunteer_eligible

          def publicly_visible = EligibilityScope.new(publicly_eligible)

          def volunteer_opportunity_eligible = EligibilityScope.new(volunteer_eligible)
        end

        attr_reader :id, :organization

        def initialize(id: 51, organization: nil)
          @id = id
          @organization = organization
        end

        def memberships = @memberships ||= NoMemberships.new
      end

      class OfferRelation
        def initialize(records)
          @records = records
          @criteria = {}
        end

        def where(criteria)
          @criteria.merge!(criteria)
          self
        end

        def find_by(criteria)
          criteria = @criteria.merge(criteria)
          @records.find do |record|
            criteria.all? do |key, value|
              if key == :contribution_need
                record.attributes[:contribution_need] == value
              elsif key == :partner_profile_id
                record.attributes[:partner_profile].nil? && value.nil?
              else
                record.attributes[key] == value
              end
            end
          end
        end
      end

      class CreatableOffer
        attr_reader :attributes

        def initialize(attributes, records)
          @attributes = attributes
          @records = records
        end

        def save
          @records << self
          true
        end
      end

      class CreatableOfferClass
        class << self
          attr_reader :records

          def reset!
            @records = []
          end

          def transaction
            yield
          end

          def active
            OfferRelation.new(records)
          end

          def new(attributes)
            CreatableOffer.new(attributes, records)
          end
        end
      end

      class OperatorRoleClass
        def self.active_for(*) = new

        def for_permission(*) = self

        def exists? = false
      end

      class AwardDispatch
        class << self
          attr_reader :calls

          def reset!
            @calls = []
          end

          def contribution_offer_recognized(offer, reviewer:)
            @calls << { offer:, reviewer: }
          end
        end
      end

      def setup
        @organization = Organization.new(id: 1, available_locales: %w(sr bs), default_locale: "sr")
        @representative = Actor.new(id: 5, organization: @organization, admin: false)
        @reviewer = Actor.new(id: 9, organization: @organization, admin: true)
        Submission.reset!
        LinkClass.reset!
        SettingClass.value = nil
        BudgetClass.record = nil
        AwardDispatch.reset!
        CreatableOfferClass.reset!
        PartnerProfile.publicly_eligible = true
        PartnerProfile.volunteer_eligible = true
        MembershipClass.available = true
      end

      def test_submission_enters_review_only_for_its_current_content_manager
        submission = Submission.new(organization: @organization, representative: @representative)

        assert_equal :forbidden,
                     SubmitPartnerProjectSubmission.call(submission, representative: @reviewer)
        assert_equal :ok,
                     SubmitPartnerProjectSubmission.call(submission, representative: @representative)
        assert_equal "submitted", submission.review_status
        assert_equal :already,
                     SubmitPartnerProjectSubmission.call(submission, representative: @representative)
      end

      def test_replacement_content_manager_can_resubmit_and_becomes_representative
        submission = Submission.new(
          organization: @organization,
          representative: @representative,
          review_status: "changes_requested"
        )
        replacement = Actor.new(id: 7, organization: @organization, admin: false)

        assert_equal :ok, SubmitPartnerProjectSubmission.call(submission, representative: replacement)
        assert_equal replacement, submission.representative
        assert_equal "submitted", submission.review_status
      end

      def test_suspended_profile_cannot_submit_or_be_approved
        PartnerProfile.publicly_eligible = false
        draft = Submission.new(
          organization: @organization,
          representative: @representative,
          profile_verified: false
        )
        submitted = Submission.new(
          organization: @organization,
          representative: @representative,
          review_status: "submitted",
          profile_verified: false
        )

        assert_equal :forbidden, SubmitPartnerProjectSubmission.call(draft, representative: @representative)
        assert_equal :invalid,
                     ApprovePartnerProjectSubmission.call(
                       submitted,
                       reviewer: @reviewer,
                       campaign_key: "community-park-12",
                       setting_class: SettingClass,
                       budget_class: BudgetClass,
                       project_class: ProjectClass,
                       link_class: LinkClass,
                       profile_class: PartnerProfile,
                       traceability: Traceability.new
                     )
        assert_equal :ok,
                     RejectPartnerProjectSubmission.call(
                       submitted,
                       reviewer: @reviewer,
                       reason: "Profile suspended before review"
                     )
      end

      def test_project_approval_uses_configured_hidden_storage_budget_and_creates_one_canonical_link
        submission = Submission.new(
          organization: @organization,
          representative: @representative,
          review_status: "submitted"
        )
        budget = Budget.new(id: 12, organization: @organization)
        BudgetClass.record = budget
        SettingClass.value = "12"
        traceability = Traceability.new

        result = ApprovePartnerProjectSubmission.call(
          submission,
          reviewer: @reviewer,
          campaign_key: " Community-Park-12 ",
          setting_class: SettingClass,
          budget_class: BudgetClass,
          project_class: ProjectClass,
          link_class: LinkClass,
          profile_class: PartnerProfile,
          campaign_validator: ->(key, organization) { key == "community-park-12" && organization == @organization },
          traceability:
        )

        assert_equal :ok, result
        assert_equal "approved", submission.review_status
        assert_equal 1, Submission.transactions
        assert_equal 1, traceability.creates.size
        create = traceability.creates.first
        assert_equal({ "sr" => "Uredimo park", "bs" => "Uredimo park" }, create[:attributes][:title])
        assert_includes create[:attributes][:description]["sr"], "&lt;script&gt;"
        refute_includes create[:attributes], :selected_at
        assert_equal "community-park-12", LinkClass.created.first[:campaign_key]
        assert_equal({ total_budget: 4_200 }, traceability.updates.first[:attributes])
      end

      def test_project_approval_fails_before_writes_when_provider_campaign_is_unverified
        submission = Submission.new(
          organization: @organization,
          representative: @representative,
          review_status: "submitted"
        )
        BudgetClass.record = Budget.new(id: 12, organization: @organization)
        SettingClass.value = "12"
        traceability = Traceability.new

        result = ApprovePartnerProjectSubmission.call(
          submission,
          reviewer: @reviewer,
          campaign_key: "campaign-typo",
          setting_class: SettingClass,
          budget_class: BudgetClass,
          project_class: ProjectClass,
          link_class: LinkClass,
          profile_class: PartnerProfile,
          traceability:,
          campaign_validator: ->(_key, _organization) { false }
        )

        assert_equal :campaign_unverified, result
        assert_empty traceability.creates
        assert_empty LinkClass.created
        assert_equal "submitted", submission.review_status
      end

      def test_project_approval_rejects_a_public_participatory_budget_as_storage
        submission = Submission.new(
          organization: @organization,
          representative: @representative,
          review_status: "submitted"
        )
        budget = Budget.new(id: 12, organization: @organization)
        budget.component.participatory_space.published = true
        BudgetClass.record = budget
        SettingClass.value = "12"

        result = ApprovePartnerProjectSubmission.call(
          submission,
          reviewer: @reviewer,
          campaign_key: "community-park-12",
          setting_class: SettingClass,
          budget_class: BudgetClass,
          project_class: ProjectClass,
          link_class: LinkClass,
          profile_class: PartnerProfile,
          campaign_validator: ->(key, organization) { key == "community-park-12" && organization == @organization },
          traceability: Traceability.new
        )

        assert_equal :invalid, result
        assert_empty LinkClass.created
      end

      def test_project_approval_fails_closed_without_configured_budget
        submission = Submission.new(
          organization: @organization,
          representative: @representative,
          review_status: "submitted"
        )

        result = ApprovePartnerProjectSubmission.call(
          submission,
          reviewer: @reviewer,
          campaign_key: "community-park-12",
          setting_class: SettingClass,
          budget_class: BudgetClass,
          project_class: ProjectClass,
          link_class: LinkClass,
          profile_class: PartnerProfile,
          campaign_validator: ->(key, organization) { key == "community-park-12" && organization == @organization },
          traceability: Traceability.new
        )

        assert_equal :invalid, result
        assert_empty LinkClass.created
      end

      def test_need_review_has_idempotent_and_reason_guarded_results
        need = Need.new(organization: @organization)

        assert_equal :invalid, RejectContributionNeed.call(need, reviewer: @reviewer, reason: " ")
        assert_equal :ok, approve_need(need)
        assert_equal :already, approve_need(need)
        assert_equal "approved", need.review_status
        assert need.updates.first[:published_at]
      end

      def test_suspended_profile_need_cannot_be_approved_but_can_be_rejected
        PartnerProfile.publicly_eligible = false
        need = Need.new(organization: @organization, profile_verified: false)

        assert_equal :invalid,
                     approve_need(need)
        assert_equal :ok,
                     RejectContributionNeed.call(
                       need,
                       reviewer: @reviewer,
                       reason: "Profile suspended before review"
                     )
        assert_equal "rejected", need.review_status
      end

      def test_need_approval_requires_a_current_volunteer_manager
        MembershipClass.available = false
        need = Need.new(organization: @organization)

        assert_equal :invalid, approve_need(need)
        assert_empty need.updates
      end

      def test_need_approval_rechecks_the_manager_after_locking_the_profile
        need = Need.new(organization: @organization)
        need.partner_profile.on_lock = -> { MembershipClass.available = false }

        assert_equal :invalid, approve_need(need)
        assert_equal 1, need.lock_count
        assert_empty need.updates
      end

      def test_concurrent_stale_need_review_returns_invalid_instead_of_raising
        need = Need.new(organization: @organization)
        need.stale_on_update = true

        assert_equal :invalid,
                     RejectContributionNeed.call(
                       need,
                       reviewer: @reviewer,
                       reason: "Concurrent review"
                     )
      end

      def test_verified_but_publicly_ineligible_profile_cannot_publish_project_or_need
        PartnerProfile.publicly_eligible = false
        submission = Submission.new(
          organization: @organization,
          representative: @representative,
          review_status: "submitted"
        )
        need = Need.new(organization: @organization)

        assert_equal :invalid,
                     ApprovePartnerProjectSubmission.call(
                       submission,
                       reviewer: @reviewer,
                       campaign_key: "community-park-12",
                       setting_class: SettingClass,
                       budget_class: BudgetClass,
                       project_class: ProjectClass,
                       link_class: LinkClass,
                       profile_class: PartnerProfile,
                       traceability: Traceability.new
                     )
        assert_equal :invalid,
                     approve_need(need)
      end

      def test_offer_transitions_fulfill_need_then_recognize_exactly_once
        need = Need.new(organization: @organization, review_status: "approved")
        contributor = Actor.new(id: 6, organization: @organization, admin: false)
        manager = Actor.new(id: 7, organization: @organization, admin: false)
        offer = Offer.new(id: 44, organization: @organization, contribution_need: need, contributor:)

        assert_equal :ok, manage(offer, manager, "accept")
        assert_equal :ok, manage(offer, contributor, "mark_delivered")
        assert_equal :ok, manage(offer, manager, "confirm")
        assert_equal "fulfilled", need.fulfillment_status
        assert_equal :ok, manage(offer, @reviewer, "recognize")
        assert_equal :already, manage(offer, @reviewer, "recognize")
        assert_equal [{ offer:, reviewer: @reviewer }], AwardDispatch.calls
      end

      def test_accept_rechecks_reserved_capacity_under_need_lock
        need = Need.new(organization: @organization, review_status: "approved", quantity: 10)
        need.remaining_quantity_value = 1
        contributor = Actor.new(id: 6, organization: @organization, admin: false)
        manager = Actor.new(id: 7, organization: @organization, admin: false)
        offer = Offer.new(
          id: 44,
          organization: @organization,
          contribution_need: need,
          contributor:,
          quantity: 2
        )

        assert_equal :invalid, manage(offer, manager, "accept")
        assert_equal "offered", offer.status
        assert_equal 1, need.lock_count
      end

      def test_beneficiary_can_decline_an_accepted_offer_to_release_capacity
        need = Need.new(organization: @organization, review_status: "approved", quantity: 10)
        contributor = Actor.new(id: 6, organization: @organization, admin: false)
        manager = Actor.new(id: 7, organization: @organization, admin: false)
        offer = Offer.new(
          id: 44,
          organization: @organization,
          contribution_need: need,
          contributor:,
          status: "accepted"
        )

        assert_equal :ok, manage(offer, manager, "decline")
        assert_equal "declined", offer.status
      end

      def test_suspended_receiving_profile_cannot_accept_a_new_commitment_but_can_decline_it
        PartnerProfile.publicly_eligible = false
        need = Need.new(organization: @organization, review_status: "approved", quantity: 10)
        contributor = Actor.new(id: 6, organization: @organization, admin: false)
        manager = Actor.new(id: 7, organization: @organization, admin: false)
        offer = Offer.new(id: 44, organization: @organization, contribution_need: need, contributor:)

        assert_equal :invalid, manage(offer, manager, "accept")
        assert offer.offered?
        assert_equal :ok, manage(offer, manager, "decline")
        assert offer.declined?
      end

      def test_need_cancellation_declines_proposals_but_preserves_confirmed_history
        need = Need.new(organization: @organization, review_status: "approved", quantity: 10)
        manager = Actor.new(id: 7, organization: @organization, admin: false)
        offered = Offer.new(
          id: 1,
          organization: @organization,
          contribution_need: need,
          contributor: @representative
        )
        accepted = Offer.new(
          id: 2,
          organization: @organization,
          contribution_need: need,
          contributor: @representative,
          status: "accepted"
        )
        confirmed = Offer.new(
          id: 3,
          organization: @organization,
          contribution_need: need,
          contributor: @representative,
          status: "confirmed"
        )
        need.offers = OfferCollection.new([offered, accepted, confirmed])

        assert_equal :ok, CancelContributionNeed.call(need:, actor: manager)
        assert offered.declined?
        assert accepted.declined?
        assert confirmed.confirmed?
        assert_equal manager, offered.updates.last[:declined_by]
        assert need.cancelled?
        assert_equal 1, need.offers.lock_count
      end

      def test_need_cancellation_refuses_while_delivery_awaits_confirmation
        need = Need.new(organization: @organization, review_status: "approved", quantity: 10)
        manager = Actor.new(id: 7, organization: @organization, admin: false)
        delivered = Offer.new(
          id: 1,
          organization: @organization,
          contribution_need: need,
          contributor: @representative,
          status: "delivered"
        )
        need.offers = OfferCollection.new([delivered])

        assert_equal :delivered_pending_confirmation, CancelContributionNeed.call(need:, actor: manager)
        assert need.open?
        assert delivered.delivered?
      end

      def test_offer_creation_locks_need_and_rejects_quantity_above_unreserved_remainder
        need = Need.new(organization: @organization, review_status: "approved", quantity: 10)
        need.remaining_quantity_value = 2
        contributor = Actor.new(id: 6, organization: @organization, admin: false)

        result, offer = CreateContributionOffer.call(
          need:,
          contributor:,
          quantity: 3,
          offer_class: CreatableOfferClass,
          profile_class: PartnerProfile
        )

        assert_equal :invalid, result
        assert_nil offer
        assert_equal 1, need.lock_count
        assert_empty CreatableOfferClass.records
      end

      def test_offer_creation_rechecks_open_state_after_need_lock
        need = Need.new(organization: @organization, review_status: "approved", quantity: 10)
        need.close_on_lock = true
        contributor = Actor.new(id: 6, organization: @organization, admin: false)

        result, = CreateContributionOffer.call(
          need:,
          contributor:,
          quantity: 1,
          offer_class: CreatableOfferClass,
          profile_class: PartnerProfile
        )

        assert_equal :invalid, result
        assert_equal 1, need.lock_count
        assert_empty CreatableOfferClass.records
      end

      def test_offer_creation_rejects_a_need_whose_receiving_profile_is_not_publicly_eligible
        PartnerProfile.publicly_eligible = false
        need = Need.new(organization: @organization, review_status: "approved", quantity: 10)
        contributor = Actor.new(id: 6, organization: @organization, admin: false)

        result, offer = CreateContributionOffer.call(
          need:,
          contributor:,
          quantity: 1,
          offer_class: CreatableOfferClass,
          profile_class: PartnerProfile
        )

        assert_equal :invalid, result
        assert_nil offer
        assert_empty CreatableOfferClass.records
      end

      def test_offer_creation_rejects_a_publicly_ineligible_offering_profile
        PartnerProfile.volunteer_eligible = false
        need = Need.new(organization: @organization, review_status: "approved", quantity: 10)
        contributor = Actor.new(id: 6, organization: @organization, admin: false)
        offering_profile = PartnerProfile.new(organization: @organization)

        result, offer = CreateContributionOffer.call(
          need:,
          contributor:,
          quantity: 1,
          partner_profile: offering_profile,
          offer_class: CreatableOfferClass,
          profile_class: PartnerProfile
        )

        assert_equal :forbidden, result
        assert_nil offer
        assert_empty CreatableOfferClass.records
      end

      def test_offer_creation_persists_quantity_within_locked_remainder
        need = Need.new(organization: @organization, review_status: "approved", quantity: 10)
        need.remaining_quantity_value = 2
        contributor = Actor.new(id: 6, organization: @organization, admin: false)

        result, offer = CreateContributionOffer.call(
          need:,
          contributor:,
          quantity: "2",
          offer_class: CreatableOfferClass,
          profile_class: PartnerProfile
        )

        assert_equal :ok, result
        assert_equal BigDecimal("2"), offer.attributes[:quantity]
        assert_equal 1, need.lock_count
        assert_equal [offer], CreatableOfferClass.records
      end

      def test_offer_transition_rejects_cross_tenant_actor
        need = Need.new(organization: @organization, review_status: "approved")
        contributor = Actor.new(id: 6, organization: @organization, admin: false)
        other_org = Organization.new(id: 2, available_locales: %w(sr), default_locale: "sr")
        outsider = Actor.new(id: 7, organization: other_org, admin: false)
        offer = Offer.new(id: 44, organization: @organization, contribution_need: need, contributor:)

        assert_equal :forbidden, manage(offer, outsider, "accept")
        assert_empty offer.updates
      end

      def test_revoked_partner_representative_cannot_deliver_even_when_they_created_offer
        need = Need.new(organization: @organization, review_status: "approved")
        former_representative = Actor.new(id: 6, organization: @organization, admin: false)
        offer = Offer.new(
          id: 44,
          organization: @organization,
          contribution_need: need,
          contributor: former_representative,
          status: "accepted"
        )
        offer.partner_profile = PartnerProfile.new

        assert_equal :forbidden, manage(offer, former_representative, "mark_delivered")
        assert_empty offer.updates
      end

      private

      def approve_need(need)
        ApproveContributionNeed.call(
          need,
          reviewer: @reviewer,
          profile_class: PartnerProfile,
          membership_class: MembershipClass
        )
      end

      def manage(offer, actor, action)
        ManageContributionOffer.call(
          offer:,
          actor:,
          action:,
          offer_class: OfferClass,
          profile_class: PartnerProfile,
          operator_role_class: OperatorRoleClass,
          award_dispatch: AwardDispatch
        )
      end
    end
  end
end

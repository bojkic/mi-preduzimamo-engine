# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/goodwill/idempotency_key"
require_relative "../../../../../app/services/decidim/bih/goodwill/award_dispatch"
require_relative "../../../../../app/services/decidim/bih/goodwill/request_identity"

module Decidim
  module Bih
    module Goodwill
      class AwardDispatchTest < Minitest::Test
        Actor = Struct.new(:id, keyword_init: true)
        Resource = Struct.new(:id, :gid, keyword_init: true) do
          def to_gid
            gid
          end
        end
        Comment = Struct.new(:id, :author, :commentable, keyword_init: true)
        ProposalVote = Struct.new(
          :author,
          :decidim_proposal_id,
          :decidim_author_id,
          :proposal,
          keyword_init: true
        )
        BudgetOrder = Struct.new(
          :user,
          :decidim_budgets_budget_id,
          :decidim_user_id,
          :budget,
          keyword_init: true
        )
        Report = Struct.new(:id, keyword_init: true)
        VolunteerOpportunity = Struct.new(:id, :author, keyword_init: true)
        VolunteerLog = Struct.new(:id, :hours, :user, keyword_init: true)
        ContributionOffer = Struct.new(
          :id,
          :contributor,
          :contribution_need_id,
          :personal,
          keyword_init: true
        ) do
          def personal?
            personal
          end
        end
        Referral = Struct.new(:referrer, keyword_init: true)

        class FakeJob
          class << self
            attr_reader :calls

            def reset!
              @calls = []
            end

            def perform_later(**payload)
              @calls << payload
              :enqueued
            end

            def name
              "Decidim::Bih::Goodwill::GoodwillAwardJob"
            end
          end
        end

        class FakeEarningRules
          attr_reader :awards

          def initialize(points: {})
            @points = points
            @awards = []
          end

          def award(owner, action, **payload)
            awards << payload.merge(owner:, action:)
            :awarded
          end

          def points_for(action)
            @points.fetch(action)
          end
        end

        class FakeLedger
          attr_reader :awards, :reversals

          def initialize
            @awards = []
            @reversals = []
          end

          def award(owner, amount, reason:, idempotency_key:, metadata:)
            awards << { owner:, amount:, reason:, idempotency_key:, metadata: }
            :posted
          end

          def reverse(transaction, **_options)
            reversals << transaction
            :reversed
          end
        end

        def setup
          FakeJob.reset!
        end

        def test_comment_created_enqueues_the_canonical_goodwill_payload
          author = Actor.new(id: 9)
          commentable = Resource.new(gid: "gid://decidim/Decidim::Proposals::Proposal/42")
          comment = Comment.new(id: 42, author:, commentable:)

          assert_equal :enqueued, AwardDispatch.comment_created(comment, author:, job: FakeJob)
          assert_equal(
            [
              {
                owner: author,
                action: "comment",
                idempotency_key: "comment:42",
                metadata: { resource_gid: "gid://decidim/Decidim::Proposals::Proposal/42" }
              }
            ],
            FakeJob.calls
          )
        end

        def test_proposal_published_enqueues_the_canonical_goodwill_payload
          author = Actor.new(id: 3)
          proposal = Resource.new(id: 7, gid: "gid://decidim/Decidim::Proposals::Proposal/7")

          assert_equal :enqueued, AwardDispatch.proposal_published(proposal, author:, job: FakeJob)
          assert_equal(
            [
              {
                owner: author,
                action: "proposal",
                idempotency_key: "proposal:7:author:3",
                metadata: { resource_gid: "gid://decidim/Decidim::Proposals::Proposal/7" }
              }
            ],
            FakeJob.calls
          )
        end

        def test_resource_liked_enqueues_the_canonical_goodwill_payload
          liker = Actor.new(id: 5)
          resource = Resource.new(gid: "gid://decidim/Decidim::Meetings::Meeting/9")

          assert_equal :enqueued, AwardDispatch.resource_liked(resource, liker:, job: FakeJob)
          assert_equal(
            [
              {
                owner: liker,
                action: "like",
                idempotency_key: "like:gid://decidim/Decidim::Meetings::Meeting/9:liker:5",
                metadata: { resource_gid: "gid://decidim/Decidim::Meetings::Meeting/9" }
              }
            ],
            FakeJob.calls
          )
        end

        def test_resource_liked_preserves_nil_resource_key_and_metadata
          liker = Actor.new(id: 5)

          AwardDispatch.resource_liked(nil, liker:, job: FakeJob)

          assert_equal "like::liker:5", FakeJob.calls.first.fetch(:idempotency_key)
          assert_equal({ resource_gid: nil }, FakeJob.calls.first.fetch(:metadata))
        end

        def test_debate_created_enqueues_the_canonical_goodwill_payload
          author = Actor.new(id: 4)
          debate = Resource.new(id: 11, gid: "gid://decidim/Decidim::Debates::Debate/11")

          assert_equal :enqueued, AwardDispatch.debate_created(debate, author:, job: FakeJob)
          assert_equal(
            [
              {
                owner: author,
                action: "debate",
                idempotency_key: "debate:11:author:4",
                metadata: { resource_gid: "gid://decidim/Decidim::Debates::Debate/11" }
              }
            ],
            FakeJob.calls
          )
        end

        def test_proposal_vote_enqueues_the_canonical_goodwill_payload
          author = Actor.new(id: 2)
          proposal = Resource.new(gid: "gid://decidim/Decidim::Proposals::Proposal/8")
          vote = ProposalVote.new(
            author:,
            decidim_proposal_id: 8,
            decidim_author_id: 2,
            proposal:
          )

          assert_equal :enqueued, AwardDispatch.proposal_vote(vote, job: FakeJob)
          assert_equal(
            [
              {
                owner: author,
                action: "vote",
                idempotency_key: "proposal_vote:8:voter:2",
                metadata: { resource_gid: "gid://decidim/Decidim::Proposals::Proposal/8" }
              }
            ],
            FakeJob.calls
          )
        end

        def test_budget_checkout_enqueues_the_canonical_goodwill_payload
          user = Actor.new(id: 6)
          budget = Resource.new(gid: "gid://decidim/Decidim::Budgets::Budget/3")
          order = BudgetOrder.new(
            user:,
            decidim_budgets_budget_id: 3,
            decidim_user_id: 6,
            budget:
          )

          assert_equal :enqueued, AwardDispatch.budget_checkout(order, job: FakeJob)
          assert_equal(
            [
              {
                owner: user,
                action: "budget_vote",
                idempotency_key: "budget_vote:3:voter:6",
                metadata: { resource_gid: "gid://decidim/Decidim::Budgets::Budget/3" }
              }
            ],
            FakeJob.calls
          )
        end

        def test_resource_gid_metadata_is_nil_when_resource_is_missing
          vote = ProposalVote.new(
            author: Actor.new(id: 2),
            decidim_proposal_id: 8,
            decidim_author_id: 2,
            proposal: nil
          )

          AwardDispatch.proposal_vote(vote, job: FakeJob)

          assert_equal({ resource_gid: nil }, FakeJob.calls.first.fetch(:metadata))
        end

        def test_verification_welcome_enqueues_the_canonical_goodwill_payload
          user = Actor.new(id: 5)

          assert_equal :enqueued, AwardDispatch.verification_welcome(user, job: FakeJob)
          assert_equal(
            [
              {
                owner: user,
                action: "verification",
                idempotency_key: "verification:5"
              }
            ],
            FakeJob.calls
          )
        end

        def test_verification_welcome_can_use_the_authorization_user_id
          user = Actor.new(id: 50)

          AwardDispatch.verification_welcome(user, user_id: 5, job: FakeJob)

          assert_equal "verification:5", FakeJob.calls.first.fetch(:idempotency_key)
        end

        def test_postal_verified_enqueues_the_canonical_goodwill_payload
          user = Actor.new(id: 5)

          assert_equal :enqueued, AwardDispatch.postal_verified(user, job: FakeJob)
          assert_equal(
            [
              {
                owner: user,
                action: "postal_verified",
                idempotency_key: "postal_verified:5"
              }
            ],
            FakeJob.calls
          )
        end

        def test_komsiluk_selected_enqueues_the_canonical_goodwill_payload
          user = Actor.new(id: 5)

          assert_equal :enqueued, AwardDispatch.komsiluk_selected(user, job: FakeJob)
          assert_equal(
            [
              {
                owner: user,
                action: "komsiluk_selected",
                idempotency_key: "komsiluk_selected:5"
              }
            ],
            FakeJob.calls
          )
        end

        def test_report_created_awards_the_canonical_goodwill_payload
          rules = FakeEarningRules.new
          author = Actor.new(id: 7)
          report = Report.new(id: 101)

          assert_equal :awarded, AwardDispatch.report_created(report, author:, earning_rules: rules)
          assert_equal(
            [{ owner: author, action: :report, idempotency_key: "bih_report:101" }],
            rules.awards
          )
        end

        def test_report_created_skips_without_author
          rules = FakeEarningRules.new

          assert_nil AwardDispatch.report_created(Report.new(id: 101), author: nil, earning_rules: rules)
          assert_empty rules.awards
        end

        def test_volunteer_availability_registered_awards_the_canonical_goodwill_payload
          rules = FakeEarningRules.new
          user = Actor.new(id: 5)
          record = Resource.new(id: 42)

          assert_equal :awarded, AwardDispatch.volunteer_availability_registered(record, user:, earning_rules: rules)
          assert_equal(
            [
              {
                owner: user,
                action: :volunteer_availability,
                idempotency_key: "volunteer_availability:42",
                metadata: { volunteer_availability_id: 42 }
              }
            ],
            rules.awards
          )
        end

        def test_volunteer_opportunity_approved_awards_the_canonical_goodwill_payload
          rules = FakeEarningRules.new
          author = Actor.new(id: 10)
          reviewer = Actor.new(id: 9)
          opportunity = VolunteerOpportunity.new(id: 42, author:)

          assert_equal :awarded, AwardDispatch.volunteer_opportunity_approved(opportunity, reviewer:, earning_rules: rules)
          assert_equal(
            [
              {
                owner: author,
                action: :volunteer_opportunity,
                idempotency_key: "volunteer_opportunity:42",
                metadata: { volunteer_opportunity_id: 42, reviewed_by_id: 9 }
              }
            ],
            rules.awards
          )
        end

        def test_volunteer_opportunity_approved_skips_without_author
          rules = FakeEarningRules.new

          assert_nil AwardDispatch.volunteer_opportunity_approved(
            VolunteerOpportunity.new(id: 42, author: nil),
            reviewer: Actor.new(id: 9),
            earning_rules: rules
          )
          assert_empty rules.awards
        end

        def test_volunteer_log_verified_posts_the_canonical_ledger_payload
          rules = FakeEarningRules.new(points: { volunteer_hour: 40 })
          ledger = FakeLedger.new
          user = Actor.new(id: 11)
          log = VolunteerLog.new(id: 77, hours: 2.5, user:)

          assert_equal :posted, AwardDispatch.volunteer_log_verified(log, ledger:, earning_rules: rules)
          assert_equal(
            [
              {
                owner: user,
                amount: 100.0,
                reason: "volunteer_hour",
                idempotency_key: "volunteer_log:77",
                metadata: { volunteer_log_id: 77, hours: 2.5 }
              }
            ],
            ledger.awards
          )
        end

        def test_recognized_personal_contribution_offer_awards_once_by_offer_id
          rules = FakeEarningRules.new
          contributor = Actor.new(id: 11)
          reviewer = Actor.new(id: 9)
          offer = ContributionOffer.new(
            id: 78,
            contributor:,
            contribution_need_id: 33,
            personal: true
          )

          assert_equal :awarded,
                       AwardDispatch.contribution_offer_recognized(offer, reviewer:, earning_rules: rules)
          assert_equal(
            [
              {
                owner: contributor,
                action: :contribution_offer,
                idempotency_key: "contribution_offer:78",
                metadata: {
                  contribution_offer_id: 78,
                  contribution_need_id: 33
                }
              }
            ],
            rules.awards
          )
        end

        def test_recognized_partner_offer_does_not_award_representative_points
          rules = FakeEarningRules.new
          offer = ContributionOffer.new(
            id: 78,
            contributor: Actor.new(id: 11),
            contribution_need_id: 33,
            personal: false
          )

          assert_nil AwardDispatch.contribution_offer_recognized(
            offer,
            reviewer: Actor.new(id: 9),
            earning_rules: rules
          )
          assert_empty rules.awards
        end

        def test_recognized_anonymized_personal_offer_does_not_award
          rules = FakeEarningRules.new
          offer = ContributionOffer.new(id: 78, contributor: nil, contribution_need_id: 33, personal: true)

          assert_nil AwardDispatch.contribution_offer_recognized(
            offer,
            reviewer: Actor.new(id: 9),
            earning_rules: rules
          )
          assert_empty rules.awards
        end

        def test_komsiluk_post_created_awards_the_canonical_goodwill_payload
          rules = FakeEarningRules.new
          author = Actor.new(id: 5)
          post = Resource.new(id: 9)

          assert_equal :awarded, AwardDispatch.komsiluk_post_created(post, author:, earning_rules: rules)
          assert_equal(
            [{ owner: author, action: :komsiluk_post, idempotency_key: "komsiluk_post:9" }],
            rules.awards
          )
        end

        def test_referral_rewarded_posts_the_canonical_ledger_payload
          rules = FakeEarningRules.new(points: { referral: 25 })
          ledger = FakeLedger.new
          referrer = Actor.new(id: 3)
          invitee = Actor.new(id: 12)
          referral = Referral.new(referrer:)

          assert_equal :posted, AwardDispatch.referral_rewarded(referral, invitee:, ledger:, earning_rules: rules)
          assert_equal(
            [
              {
                owner: referrer,
                amount: 25,
                reason: "referral",
                idempotency_key: "referral:12",
                metadata: { invitee_id: 12 }
              }
            ],
            ledger.awards
          )
        end

        def test_manual_award_posts_the_canonical_ledger_payload
          ledger = FakeLedger.new
          owner = Actor.new(id: 6)
          admin = Actor.new(id: 9)
          at = Time.utc(2026, 6, 18, 12, 34, 56)
          request_key = "01234567-89ab-4cde-8f01-23456789abcd"

          result = Time.stub(:current, at) do
            AwardDispatch.manual_award(
              owner,
              amount: 30,
              admin:,
              reason: "Pomoc u akciji",
              request_key:, ledger:
            )
          end

          assert_equal :posted, result
          assert_equal(
            [
              {
                owner:,
                amount: 30,
                reason: "manual",
                idempotency_key: "request:manual:9:#{request_key}",
                metadata: {
                  admin_id: 9,
                  admin_reason: "Pomoc u akciji"
                }
              }
            ],
            ledger.awards
          )
        end

        def test_reverse_transaction_delegates_to_the_ledger
          ledger = FakeLedger.new
          transaction = Object.new

          assert_equal :reversed, AwardDispatch.reverse_transaction(transaction, ledger:)
          assert_equal [transaction], ledger.reversals
        end
      end
    end
  end
end

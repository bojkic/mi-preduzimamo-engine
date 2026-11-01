# frozen_string_literal: true

require "test_helper"
require "date"
require_relative "../../../../../app/services/decidim/bih/goodwill/idempotency_key"

module Decidim
  module Bih
    module Goodwill
      class IdempotencyKeyTest < Minitest::Test
        def test_comment_key_matches_the_historical_literal
          assert_equal "comment:42", IdempotencyKey.comment(42)
        end

        def test_proposal_key_matches_the_historical_literal
          assert_equal "proposal:7:author:3", IdempotencyKey.proposal(7, 3)
        end

        def test_like_key_matches_the_historical_literal_with_a_gid
          gid = "gid://decidim/Decidim::Proposals::Proposal/9"

          assert_equal "like:#{gid}:liker:5", IdempotencyKey.like(gid, 5)
        end

        def test_like_key_preserves_nil_gid_interpolation
          assert_equal "like::liker:5", IdempotencyKey.like(nil, 5)
        end

        def test_debate_key_matches_the_historical_literal
          assert_equal "debate:11:author:4", IdempotencyKey.debate(11, 4)
        end

        def test_proposal_vote_key_matches_the_historical_literal
          assert_equal "proposal_vote:8:voter:2", IdempotencyKey.proposal_vote(8, 2)
        end

        def test_budget_vote_key_matches_the_historical_literal
          assert_equal "budget_vote:6:voter:1", IdempotencyKey.budget_vote(6, 1)
        end

        def test_report_key_matches_the_historical_literal
          assert_equal "bih_report:101", IdempotencyKey.report(101)
        end

        def test_volunteer_availability_key_matches_the_historical_literal
          assert_equal "volunteer_availability:42", IdempotencyKey.volunteer_availability(42)
        end

        def test_volunteer_opportunity_key_matches_the_historical_literal
          assert_equal "volunteer_opportunity:43", IdempotencyKey.volunteer_opportunity(43)
        end

        def test_volunteer_log_key_matches_the_historical_literal
          assert_equal "volunteer_log:77", IdempotencyKey.volunteer_log(77)
        end

        def test_daily_key_uses_person_and_sarajevo_work_date_across_opportunities
          assert_equal "volunteer_day:11:2026-10-25", IdempotencyKey.volunteer_day(11, Date.new(2026, 10, 25))
          assert_equal "volunteer_day:11:2026-10-26", IdempotencyKey.volunteer_day(11, Date.new(2026, 10, 26))
        end

        def test_whole_proposal_key_is_distinct_from_historical_term_key
          assert_equal "volunteer_proposal:series:weekly-a", IdempotencyKey.volunteer_proposal("series:weekly-a")
          refute_equal IdempotencyKey.volunteer_opportunity(43), IdempotencyKey.volunteer_proposal("opportunity:43")
        end

        def test_contribution_offer_key_is_stable
          assert_equal "contribution_offer:78", IdempotencyKey.contribution_offer(78)
        end

        def test_volunteer_org_bonus_key_matches_the_literal
          assert_equal "volunteer_org_bonus:77", IdempotencyKey.volunteer_org_bonus(77)
        end

        def test_organization_spending_request_key_matches_the_literal
          assert_equal "organization_spending_request:88", IdempotencyKey.organization_spending_request(88)
        end

        def test_verification_key_matches_the_historical_literal
          assert_equal "verification:5", IdempotencyKey.verification(5)
        end

        def test_postal_verified_key_matches_the_historical_literal
          assert_equal "postal_verified:5", IdempotencyKey.postal_verified(5)
        end

        def test_komsiluk_selected_key_matches_the_historical_literal
          assert_equal "komsiluk_selected:5", IdempotencyKey.komsiluk_selected(5)
        end

        def test_komsiluk_post_key_matches_the_historical_literal
          assert_equal "komsiluk_post:9", IdempotencyKey.komsiluk_post(9)
        end

        def test_referral_key_matches_the_historical_literal
          assert_equal "referral:12", IdempotencyKey.referral(12)
        end
      end
    end
  end
end

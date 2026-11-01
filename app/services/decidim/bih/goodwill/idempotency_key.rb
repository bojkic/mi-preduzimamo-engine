# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Single source of truth for the idempotency keys that guard goodwill
      # awards. These keys are the ONLY thing standing between a duplicated
      # event (an event published twice, a vote→un-vote→re-vote, a re-checkout,
      # a re-run job) and a double award, so they were previously hand-built as
      # string literals at every award site. Centralising them here keeps the
      # exact shape in ONE place.
      #
      # IMPORTANT: the produced strings are part of the durable contract — they
      # are persisted on existing transactions and compared on every award. Any
      # change here that alters an existing key would silently re-award every
      # citizen. The builders below reproduce the historical literals
      # BYTE-FOR-BYTE; a characterization test asserts the exact strings.
      module IdempotencyKey
        module_function

        # A new civic comment by its author.
        def comment(comment_id)
          "comment:#{comment_id}"
        end

        # A published proposal, keyed on (proposal, author) so each co-author is
        # recognised once and a republish never re-awards.
        def proposal(proposal_id, author_id)
          "proposal:#{proposal_id}:author:#{author_id}"
        end

        # A resource "like", keyed on (resource gid, liker). +resource_gid+ is
        # interpolated as-is (a GlobalID or nil), matching the original literal.
        def like(resource_gid, liker_id)
          "like:#{resource_gid}:liker:#{liker_id}"
        end

        # A new debate, keyed on (debate, author).
        def debate(debate_id, author_id)
          "debate:#{debate_id}:author:#{author_id}"
        end

        # A proposal vote/support, keyed on (proposal, voter) — NOT the vote row
        # id — so vote→un-vote→re-vote can't re-award the same citizen.
        def proposal_vote(proposal_id, voter_id)
          "proposal_vote:#{proposal_id}:voter:#{voter_id}"
        end

        # A participatory budget checkout, keyed on (budget, voter) — NOT the
        # order row id — so a cancel→re-checkout on the SAME budget can't
        # re-award.
        def budget_vote(budget_id, voter_id)
          "budget_vote:#{budget_id}:voter:#{voter_id}"
        end

        # A public civic report, keyed on the report row.
        def report(report_id)
          "bih_report:#{report_id}"
        end

        # A citizen's first volunteer availability registration.
        def volunteer_availability(record_id)
          "volunteer_availability:#{record_id}"
        end

        # A volunteer opportunity approved by an admin.
        def volunteer_opportunity(opportunity_id)
          "volunteer_opportunity:#{opportunity_id}"
        end

        # A verified volunteer-hours log.
        def volunteer_log(log_id)
          "volunteer_log:#{log_id}"
        end

        def volunteer_day(user_id, work_date)
          "volunteer_day:#{user_id}:#{work_date.iso8601}"
        end

        def volunteer_proposal(identity)
          "volunteer_proposal:#{identity}"
        end

        # LFBN-recognized delivery of one non-cash contribution offer. The
        # offer row is the durable exactly-once boundary.
        def contribution_offer(offer_id)
          "contribution_offer:#{offer_id}"
        end

        # Organization-funded bonus for one verified volunteer-hours log.
        def volunteer_org_bonus(log_id)
          "volunteer_org_bonus:#{log_id}"
        end

        # Operator-approved organization spending request.
        def organization_spending_request(request_id)
          "organization_spending_request:#{request_id}"
        end

        # The first successful citizen verification grant.
        def verification(user_id)
          "verification:#{user_id}"
        end

        # The first successful postal-letter verification grant.
        def postal_verified(user_id)
          "postal_verified:#{user_id}"
        end

        # The first komsiluk assignment for a citizen.
        def komsiluk_selected(user_id)
          "komsiluk_selected:#{user_id}"
        end

        # A Komšiluk board post by its author.
        def komsiluk_post(post_id)
          "komsiluk_post:#{post_id}"
        end

        # A verified referral payout, keyed on the invitee.
        def referral(invitee_id)
          "referral:#{invitee_id}"
        end
      end
    end
  end
end

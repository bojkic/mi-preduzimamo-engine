# frozen_string_literal: true

# Award goodwill points when a citizen votes/supports a proposal. Proposal votes
# emit no ActiveSupport notification in 0.31.7 (the deferred earn source), so we
# hook the model directly: after the vote commits, enqueue the award off the
# request path. EarningRules applies the per-day vote cap; the idempotency key is
# scoped to (proposal, voter) so un-vote/re-vote cannot double award.
module Decidim
  module Bih
    module Goodwill
      module ProposalVoteAwardOverride
        def self.prepended(base)
          base.after_create_commit :award_goodwill_for_vote
        end

        def award_goodwill_for_vote
          return unless author.is_a?(Decidim::UserBaseEntity)

          Decidim::Bih::Goodwill::AwardDispatch.proposal_vote(self)
        rescue StandardError => e
          Rails.logger.error("[goodwill] vote award: #{e.class}: #{e.message}")
        end
      end
    end
  end
end

Decidim::Proposals::ProposalVote.prepend(Decidim::Bih::Goodwill::ProposalVoteAwardOverride)

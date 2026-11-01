# frozen_string_literal: true

# Award goodwill points when a citizen completes budget checkout. Decidim
# Budgets::Order has no AS notification for checkout in 0.31.7, so we hook the
# model directly via after_update_commit. The idempotency key is keyed on
# (budget, voter), so cancel/re-checkout cannot double award the same budget.
#
# THE WALL: this override ONLY enqueues a background award for PARTICIPATING —
# it never touches the order's line_items, checked_out_at, or any vote-weight
# attribute. The binding vote remains entirely unaffected.
module Decidim
  module Bih
    module Goodwill
      module BudgetVoteAwardOverride
        def self.prepended(base)
          base.after_update_commit :award_goodwill_for_budget_vote
        end

        def award_goodwill_for_budget_vote
          # Only fire on the transition nil -> timestamp (first checkout).
          # saved_change_to_checked_out_at? is true on ANY change to that column;
          # we guard that the *previous* value was nil to exclude re-checkouts.
          return unless saved_change_to_checked_out_at?
          return if checked_out_at.blank?
          return unless saved_changes["checked_out_at"].first.nil?
          return unless user.is_a?(Decidim::User)

          Decidim::Bih::Goodwill::AwardDispatch.budget_checkout(self)
        rescue StandardError => e
          Rails.logger.error("[goodwill] budget vote award: #{e.class}: #{e.message}")
        end
      end
    end
  end
end

Decidim::Budgets::Order.prepend(Decidim::Bih::Goodwill::BudgetVoteAwardOverride)

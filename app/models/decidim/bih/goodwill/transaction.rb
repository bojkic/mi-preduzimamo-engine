# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # A ledger transaction: an atomic, balanced set of entries.
      #   INVARIANT: entries.sum(:amount) == 0 (double-entry).
      #   APPEND-ONLY: corrections are made by posting a NEW reversing
      #   transaction, never by editing/deleting this one.
      class Transaction < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_transactions"

        KINDS = %w(earn gift regrant redeem adjustment).freeze

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        has_many :entries,
                 class_name: "Decidim::Bih::Goodwill::Entry",
                 foreign_key: "decidim_bih_goodwill_transaction_id",
                 inverse_of: :ledger_transaction,
                 dependent: :restrict_with_exception

        has_one :reward_fulfillment,
                class_name: "Decidim::Bih::Goodwill::RewardFulfillment",
                foreign_key: "decidim_bih_goodwill_transaction_id",
                inverse_of: :ledger_transaction,
                dependent: :restrict_with_exception

        validates :kind, presence: true, inclusion: { in: KINDS }
        validates :idempotency_key,
                  uniqueness: { scope: :decidim_organization_id },
                  allow_nil: true

        validate :entries_present
        validate :entries_balance_to_zero
        validate :entries_share_organization

        before_update :prevent_mutation
        # prepend so the append-only guard fires before the association's
        # dependent: :restrict_with_exception callback (authoritative error).
        before_destroy :prevent_destroy, prepend: true

        scope :earnings, -> { where(kind: "earn") }

        # Reason for the 2026-09 point-scale recalibration's corrective
        # transactions (Decidim::Bih::Goodwill::Rescale). Named HERE — not in
        # Rescale — because CONTRIBUTION_ADJUSTMENT_REASONS below is the single
        # definition of "what counts toward contribution_score" that BOTH
        # Ledger#build_and_save (the writer) and Account#recomputed_contribution
        # (what decidim_bih:goodwill:reconcile trusts) must consult. Before this
        # constant existed the two disagreed silently: the writer never bumped
        # cached_contribution for an "adjustment", and a later reconcile run
        # would then "fix" the drift by wiping the rescale back out. Rescale
        # reads its REASON from here so the two can never define it differently.
        RESCALE_2026_09_REASON = "rescale_2026_09"

        # "adjustment" transactions whose credits ALSO count toward
        # contribution score, alongside every "earn". Deliberately a narrow,
        # explicit allow-list (never a broad "kind == adjustment" match) — an
        # ordinary correction (gift, redeem, reversal, or any future
        # adjustment) must never accidentally move recognition.
        CONTRIBUTION_ADJUSTMENT_REASONS = [RESCALE_2026_09_REASON, "volunteer_day_correction"].freeze

        def reversing?
          reason.to_s.start_with?("reversal_of:") || metadata.to_h.key?("reverses_transaction_id")
        end

        # True for the narrow set of "adjustment" transactions that are allowed
        # to move contribution_score (see CONTRIBUTION_ADJUSTMENT_REASONS).
        def contribution_adjustment?
          kind.to_s == "adjustment" && CONTRIBUTION_ADJUSTMENT_REASONS.include?(reason.to_s)
        end

        # True when this transaction's credits should count toward the owner's
        # recognition (contribution) score: every "earn", plus the specific
        # adjustment reasons above. THE single definition consulted by both
        # Ledger#build_and_save and Account#recomputed_contribution.
        def contributes_to_score?
          kind.to_s == "earn" || contribution_adjustment?
        end

        # The total points CREDITED by this transaction: the sum of its positive
        # entries (an earn/gift/regrant credits the recipient's account). For a
        # balanced earn this equals the points awarded to the owner — callers
        # (e.g. ReportIntake#awarded_points) use it to surface "+N bodova".
        def credited_amount
          entries.select { |e| e.amount.positive? }.sum(&:amount)
        end

        private

        def entries_present
          errors.add(:base, :no_entries) if entries.to_a.empty?
        end

        def entries_balance_to_zero
          entries_array = entries.to_a
          return if entries_array.empty?

          sum = entries_array.sum { |e| e.amount.to_i }
          errors.add(:base, :unbalanced) unless sum.zero?
        end

        def entries_share_organization
          return unless organization

          invalid = entries.to_a.any? do |entry|
            entry.organization != organization || entry.account&.organization != organization
          end
          errors.add(:entries, :invalid) if invalid
        end

        def prevent_mutation
          raise Decidim::Bih::Goodwill::AppendOnlyError, "goodwill transactions are append-only"
        end

        def prevent_destroy
          raise Decidim::Bih::Goodwill::AppendOnlyError, "goodwill transactions are append-only"
        end
      end
    end
  end
end

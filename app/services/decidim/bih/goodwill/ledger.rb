# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Posting facade for the goodwill points ledger. Every public posting method
      # writes a BALANCED (sum-zero) transaction inside a single DB transaction.
      # This is the only place that creates Entry rows. PORO; matches the
      # Decidim::Bih::ReportIntake service conventions.
      class Ledger
        # Convenience: award `amount` points to `owner` (a Decidim::User, incl.
        # groups) as an "earn" — debit the org system account, credit the owner.
        # Returns the Transaction, or nil when amount <= 0 or the idempotency key
        # was already used (already awarded).
        def self.award(owner, amount, reason:, idempotency_key: nil, metadata: {})
          new.award(owner, amount, reason:, idempotency_key:, metadata:)
        end

        def award(owner, amount, reason:, idempotency_key: nil, metadata: {})
          amount = amount.to_i
          return nil unless amount.positive?
          return nil unless owner.respond_to?(:organization) && owner.organization

          organization = owner.organization
          result = nil

          ActiveRecord::Base.transaction do
            user_account = account_for(owner)
            AccountLocks.lock!(user_account)
            if idempotency_key && (existing = Transaction.find_by(organization:, idempotency_key:))
              verify_replay!(existing, kind: "earn", reason:, metadata:,
                entries: [{ account: system_account_for(organization), amount: -amount }, { account: user_account, amount: }])
              result = nil
            else
              system_account = system_account_for(organization)
              user_account = account_for(owner)
              result = build_and_save(
                organization:,
                kind: "earn",
                reason:,
                idempotency_key:,
                metadata:,
                entries: [
                  { account: system_account, amount: -amount }, # debit issuance
                  { account: user_account, amount: } # credit citizen/group
                ]
              )
            end
          end

          # Notify the earner in their Decidim notifications bell — but ONLY for a
          # real, fresh earn (result present; idempotency-dropped awards are nil).
          # This is the SINGLE seam every earn passes through (EarningRules#award,
          # volunteer-hour verification and referral rewards all land here), so it
          # fires EXACTLY once per earn and never for gift/regrant/redeem/
          # adjustment (those go through transfer/spend/post, not #award).
          if result
            ActiveRecord.after_all_transactions_commit do
            resource_gid = (metadata || {}).with_indifferent_access[:resource_gid]
            notify_points_earned(owner, amount, reason, resource_gid:)
            # Mirror the earn into Decidim's native gamification badge so the
            # core /profiles/:nickname/badges page lights up. This is the SINGLE
            # writer into the :goodwill_contributor badge score; the badge's
            # reset lambda (engine.rb) recomputes from cached_contribution, so
            # reset_badges is drift-free. Earn-only (never gift/redeem) and
            # citizen-only (groups never earn recognition).
            # ContributionProjection.after_commit owns the exact badge score.

            # Nagrada-prag: provjeri da li je ovaj earn prešao prag za pozivnicu
            # za lansiranje. Nikad inline — job se pušta TEK POSLIJE COMMITA,
            # jer bi prerano pušten job pročitao stari zbir i propustio prag.
            maybe_issue_launch_invitation(owner)
            end
          end

          result
        rescue ActiveRecord::RecordNotUnique
          # Lost the idempotency race; treat as already-awarded.
          nil
        end

        # Generic balanced posting. `entries` is an array of { account:, amount: }
        # whose amounts MUST sum to zero. Opens its own DB transaction.
        # rubocop:disable Metrics/ParameterLists
        def post(organization:, kind:, entries:, reason: nil, idempotency_key: nil, metadata: {})
          ActiveRecord::Base.transaction do
            AccountLocks.lock!(entries.map { |entry| entry[:account] })
            existing = idempotency_key && Transaction.find_by(organization:, idempotency_key:)
            if existing
              verify_replay!(existing, kind:, reason:, entries:, metadata:)
              existing
            else
              check_available!(entries)
              build_and_save(organization:, kind:, entries:, reason:, idempotency_key:, metadata:)
            end
          end
        end

        # Transfer points between two owners' WALLETS — gift (citizen -> org) or
        # regrant (org -> volunteer). Debits `from_owner`, credits `to_owner`.
        # Does NOT touch contribution_score (only "earn" does), so recognition
        # stays earned-only and gifting never moves a leaderboard rank. Guarded
        # against overdraw under a per-spender advisory lock; raises
        # InsufficientBalanceError if the wallet can't cover it.
        def transfer(from_owner:, to_owner:, amount:, kind:, reason: nil, idempotency_key: nil, metadata: {})
          amount = amount.to_i
          raise ArgumentError, "amount must be positive" unless amount.positive?
          raise ArgumentError, "cannot transfer to self" if same_owner?(from_owner, to_owner)

          organization = from_owner.organization
          raise ArgumentError, "owners must share an organization" unless to_owner.organization == organization

          result = nil

          ActiveRecord::Base.transaction do
            from_account = account_for(from_owner)
            to_account = account_for(to_owner)
            AccountLocks.lock!(from_account, to_account)
            entries = [{ account: from_account, amount: -amount }, { account: to_account, amount: }]
            existing = idempotency_key && Transaction.find_by(organization:, idempotency_key:)
            if existing
              verify_replay!(existing, kind:, reason:, entries:, metadata:)
              result = existing
            else
              check_available!(entries)
              result = build_and_save(organization:, kind:, reason:, idempotency_key:, metadata:, entries:)
            end
          end

          result
        rescue ActiveRecord::RecordNotUnique
          nil
        end

        # Spend points from an owner's wallet to the org system account (e.g.
        # redeeming a reward). Overdraw-guarded; raises InsufficientBalanceError.
        # rubocop:enable Metrics/ParameterLists

        # rubocop:disable Metrics/ParameterLists
        def spend(owner:, amount:, kind:, reason: nil, idempotency_key: nil, metadata: {})
          amount = amount.to_i
          raise ArgumentError, "amount must be positive" unless amount.positive?

          organization = owner.organization
          ActiveRecord::Base.transaction do
            account = account_for(owner)
            lock_account!(account)
            # Re-read AFTER acquiring the lock: the cached_balance loaded above
            # is a pre-lock snapshot, so a concurrent spend that committed while
            # we waited for the lock would otherwise let a stale balance pass the
            # guard and overdraw the wallet negative.
            account.reload

            system_account = system_account_for(organization)
            entries = [{ account:, amount: -amount }, { account: system_account, amount: }]
            existing = idempotency_key && Transaction.find_by(organization:, idempotency_key:)
            if existing
              verify_replay!(existing, kind:, reason:, entries:, metadata:)
              existing
            else
              check_available!(entries)
              build_and_save(organization:, kind:, reason:, idempotency_key:, metadata:, entries:)
            end
          end
        end
        # rubocop:enable Metrics/ParameterLists

        # Append-only correction: post a mirror-image transaction reversing every
        # entry of `original`. Used by future admin tooling so corrections never
        # tempt an UPDATE/DELETE of the original.
        def reverse(original, contribution: false, actor: nil, fulfillment_status: "reversed", fulfillment_source: nil, fulfillment_metadata: {})
          raise ArgumentError, "invalid refund state" unless %w(canceled reversed).include?(fulfillment_status)
          if contribution && (original.kind != "earn" || original.reason != "volunteer_day")
            raise ArgumentError, "only a volunteer-day earn can receive a contribution correction"
          end
          if original.kind == "earn"
            correction = SourceCreditCorrection.revoke(original, actor:)
            return correction&.settlement&.ledger_transaction
          end
          raise ArgumentError, "cannot reverse a correction" if original.kind == "adjustment" || original.reversing?

          ActiveRecord::Base.transaction do
            fulfillment = original.reward_fulfillment
            fulfillment&.lock!
            if fulfillment && fulfillment_status == "canceled" && !fulfillment.open? && fulfillment.status != "canceled"
              raise ArgumentError, "fulfillment cannot be canceled"
            end
            reversal = post(
              organization: original.organization, kind: "adjustment", reason: "reversal_of:#{original.id}",
              idempotency_key: "reversal_of:#{original.id}", metadata: { reverses_transaction_id: original.id },
              entries: original.entries.map { |entry| { account: entry.account, amount: -entry.amount } }
            )
            source = fulfillment_source || (actor ? "admin" : "system")
            role = source == "public" ? "citizen" : (actor ? "admin" : "system")
            if fulfillment && fulfillment.status != fulfillment_status
              changed = fulfillment.mark!(fulfillment_status, by: actor, source:, actor_role: role,
                metadata: fulfillment_metadata.merge(reversal_transaction_id: reversal.id))
              raise ArgumentError, "fulfillment refund transition refused" unless changed
            end
            reversal
          end
        end

        # Idempotent account lookup/creation for an owner (citizen or group).
        def account_for(owner)
          find_or_create_account(
            organization: owner.organization,
            owner_type: owner.class.base_class.name,
            owner_id: owner.id,
            kind: "user"
          )
        end

        def system_account_for(organization)
          find_or_create_account(
            organization:,
            owner_type: nil,
            owner_id: nil,
            kind: "system"
          )
        end

        private

        # Publish the in-app "points earned" notification for the earner. WRAPPED
        # IN RESCUE: a notification failure (Sidekiq down, i18n hiccup, anything)
        # must NEVER break or roll back the ledger award — the points are already
        # committed by the time we get here. Groups never earn (EarningRules
        # guards them and recognition is citizen-only), but we guard once more so
        # an unexpected group earn can't ping a non-citizen.
        #
        # +resource_gid+ — optional GlobalID string of the source resource (e.g. a
        # proposal, comment, debate, budget, or report status page URL key). When
        # present it is stored in +extra+ and resolved by PointsEarnedEvent into a
        # clickable link in the notification bell.
        def notify_points_earned(owner, amount, reason, resource_gid: nil)
          return if owner.respond_to?(:group?) && owner.group?

          extra = { amount: amount.to_i, reason: reason.to_s }
          extra[:resource_gid] = resource_gid.to_s if resource_gid.present?

          Decidim::EventsManager.publish(
            event: "decidim.events.bih.goodwill.points_earned",
            event_class: Decidim::Bih::Goodwill::PointsEarnedEvent,
            resource: owner, # the earner themselves (User#can_participate? => true)
            affected_users: [owner],
            force_send: true, # bypass the Publicable notifiable? gate
            extra:
          )
        rescue StandardError => e
          Rails.logger.error(
            "[Goodwill] points-earned notification failed for owner #{owner&.id} " \
            "(#{e.class}: #{e.message}); award unaffected"
          )
          nil
        end

        # Increment the native Decidim gamification badge for this earn. WRAPPED
        # IN RESCUE for the same reason as notify_points_earned: a gamification
        # failure (badge not registered, DB hiccup, anything) must NEVER break or
        # roll back the award — points are already committed by the time we run.
        # Skip groups (they never earn recognition). increment_score itself
        # no-ops on a non-positive amount or a non-UserBaseEntity, so this is
        # safe to call after the citizen guard.
        def mirror_badge_score(owner, amount)
          return if owner.respond_to?(:group?) && owner.group?

          Decidim::Gamification.set_score(owner, :goodwill_contributor, account_for(owner).reload.contribution_score)
        rescue StandardError => e
          Rails.logger.error(
            "[Goodwill] badge mirror failed for owner #{owner&.id} " \
            "(#{e.class}: #{e.message}); award unaffected"
          )
          nil
        end

        # Pušta pokušaj izdavanja pozivnice za lansiranje poslije commita.
        # Tiho odustaje kad nagrada nije aktivna — ovo se zove na SVAKOJ
        # dodjeli bodova, pa mora biti jeftino i nikad ne smije dizati izuzetak.
        def maybe_issue_launch_invitation(owner)
          return unless owner.is_a?(Decidim::User)
          return unless Decidim::Bih::Goodwill::LaunchInvitation.enabled?(owner.organization)

          ActiveRecord.after_all_transactions_commit do
            Decidim::Bih::Goodwill::LaunchInvitationJob.perform_later(owner.id)
          rescue StandardError => e
            # Kad je registracija odgođena do commita (uobičajen slučaj, jer
            # EarningRules#award otvara svoju transakciju), Rails ovaj blok
            # izvršava POSLIJE stvarnog COMMIT-a, bez sopstvenog rescue-a — pa
            # bi izuzetak ovdje (npr. Redis/Sidekiq zastoj) inače procurio kroz
            # transaction do...end i srušio poziv koji je bodove već upisao.
            Rails.logger.error("[goodwill] launch invitation enqueue failed: #{e.class}: #{e.message}")
            nil
          end
        rescue StandardError => e
          # Ovo i dalje pokriva enabled? i sâmu registraciju (after_all_transactions_commit
          # poziv), za slučaj da ona sinhrono digne izuzetak prije nego što se blok zakaže.
          Rails.logger.error("[goodwill] launch invitation hook failed: #{e.class}: #{e.message}")
          nil
        end

        # Serialise concurrent spends on one account so the balance check and the
        # debit are atomic (prevents double-spend / overdraw under parallel jobs).
        def lock_account!(account)
          AccountLocks.lock!(account)
        end

        def check_available!(entries)
          entries.group_by { |entry| entry[:account].id }.each_value do |group|
            account = group.first[:account]
            next if account.kind == "system"
            delta = group.sum { |entry| entry[:amount].to_i }
            raise InsufficientBalanceError if account.reload.balance + delta < 0
          end
        end

        def verify_replay!(existing, kind:, reason:, entries:, metadata:)
          requested = entries.map { |entry| [entry[:account].id, entry[:amount].to_i] }.sort
          actual = existing.entries.map { |entry| [entry.account.id, entry.amount] }.sort
          raise ArgumentError, "request key reused with different payload" unless existing.kind == kind.to_s && existing.reason.to_s == reason.to_s && actual == requested && existing.metadata.to_h == metadata.to_h.deep_stringify_keys
        end

        def same_owner?(left, right)
          left.class.base_class.name == right.class.base_class.name && left.id == right.id
        end

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/ParameterLists, Metrics/PerceivedComplexity
        def build_and_save(organization:, kind:, entries:, reason: nil, idempotency_key: nil, metadata: {})
          raise ArgumentError, "entries required" if entries.blank?

          mismatched_accounts = entries.filter_map do |entry|
            account = entry[:account]
            next account unless account.respond_to?(:organization)
            next if account.organization == organization

            account
          end
          raise ArgumentError, "all ledger accounts must belong to the transaction organization" if mismatched_accounts.any?

          sum = entries.sum { |e| e[:amount].to_i }
          raise ArgumentError, "entries must sum to zero (got #{sum})" unless sum.zero?

          txn = Transaction.new(organization:, kind:, reason:, idempotency_key:, metadata: metadata || {})
          entries.each do |e|
            txn.entries.build(organization:, account: e[:account], amount: e[:amount].to_i)
          end
          txn.save!

          # Maintain the cached aggregates atomically, in the SAME transaction as
          # the entries (callers wrap this in ActiveRecord::Base.transaction). O(1)
          # per write vs O(lifetime-entries) per read. amounts are integers, so
          # the interpolation is injection-safe.
          entries.each do |e|
            amount = e[:amount].to_i
            earn_credit = contribution_credit_for(txn, e[:account], amount)
            # Cached ledger aggregates are maintained with an atomic SQL update
            # in the same transaction as the append-only entries.
            # rubocop:disable Rails/SkipsModelValidations
            Account.where(id: e[:account].id).update_all(
              "cached_balance = cached_balance + #{amount}, " \
              "cached_contribution = cached_contribution + #{earn_credit}"
            )
            # rubocop:enable Rails/SkipsModelValidations
            # Keep the in-memory account object consistent for any caller holding it.
            e[:account].assign_attributes(
              cached_balance: e[:account].cached_balance + amount,
              cached_contribution: e[:account].cached_contribution + earn_credit
            )
          end
          entries.map { |entry| entry[:account] }.uniq(&:id).each { |account| ContributionProjection.after_commit(account) if account.kind == "user" }
          txn
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/ParameterLists, Metrics/PerceivedComplexity

        # How much of this ENTRY's signed amount should count toward the
        # account's contribution (recognition) score. Single writer-side use of
        # Transaction#contributes_to_score? (see that method — it is the SAME
        # definition Account#recomputed_contribution consults, so the cached
        # column and reconcile's recomputation can never drift apart again).
        #
        # Only ever credits a "user" account (never "system" — the system
        # account is always the OTHER, mirror-image side of a balanced
        # posting and must never itself accrue contribution).
        #
        # "earn" credits ONLY a positive amount — every real earn credits the
        # user side with a positive amount and debits the system side with a
        # negative one (enforced upstream: Ledger#award/#post never build a
        # negative-amount "earn" entry for a user), so this clamp is a no-op
        # for earn in practice and a defensive belt for it specifically.
        #
        # A contribution_adjustment? (currently only the 2026-09 rescale) is
        # the ONE case that credits the FULL SIGNED amount, positive or
        # negative — that is the entire point of Rescale: an account's
        # recognition can move down as well as up when the point schedule for
        # an action it already earned changes.
        def contribution_credit_for(txn, account, amount)
          return 0 unless account.respond_to?(:kind) && account.kind == "user"
          return amount if txn.kind.to_s == "earn" && amount.positive?
          return amount if txn.contribution_adjustment?

          0
        end

        # find_or_create that tolerates a concurrent insert (the unique indexes
        # raise RecordNotUnique; we then re-find rather than aborting the award).
        def find_or_create_account(attrs)
          Account.find_or_create_by!(attrs)
        rescue ActiveRecord::RecordNotUnique
          # Re-find with the SAME attrs (incl. :kind) so a system and a user
          # account for the same (org, owner) can never be confused.
          Account.find_by!(attrs)
        end
      end
    end
  end
end

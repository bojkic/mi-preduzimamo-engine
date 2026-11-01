# frozen_string_literal: true

require "active_model"

module Decidim
  module Bih
    module Goodwill
      # A double-entry ledger account. Owned polymorphically by a Decidim::User
      # (citizens AND groups; in 0.31.7 a group is a User with
      # extended_data["group"]=true). The single owner-less account with
      # kind="system" per organization is the issuance counterparty for "earn".
      #
      # Two figures are derived from the same entries:
      #   * #contribution_score — corrected recognition: the sum of credits booked
      #     by "earn" transactions. Never reduced by gifting/redeeming.
      #   * #balance — the spendable wallet: the sum of ALL signed entries.
      class Account < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_accounts"

        KINDS = %w(user system).freeze

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        belongs_to :owner, polymorphic: true, optional: true

        # Append-only: never cascade-delete postings.
        has_many :entries,
                 class_name: "Decidim::Bih::Goodwill::Entry",
                 foreign_key: "decidim_bih_goodwill_account_id",
                 dependent: :restrict_with_exception,
                 inverse_of: :account

        validates :kind, presence: true, inclusion: { in: KINDS }
        validate :system_account_has_no_owner
        validate :user_account_has_owner

        scope :user_accounts, -> { where(kind: "user") }
        scope :system_accounts, -> { where(kind: "system") }

        # Citizen accounts only (excludes organization GROUPS — a group is a
        # Decidim::User with extended_data group:true). This is the recognition
        # cohort: the leaderboard and an individual's rank are both computed over
        # exactly this set, so the group-exclusion lives in ONE place.
        # NOT EXISTS is NULL-safe and avoids owner_type coupling (the stored type
        # is the STI base Decidim::UserBaseEntity, not Decidim::User).
        scope :citizen_accounts, lambda {
          user_accounts.where(owner_type: Decidim::User.base_class.name).where(
            "NOT EXISTS (SELECT 1 FROM decidim_users u " \
            "WHERE u.id = decidim_bih_goodwill_accounts.owner_id AND u.extended_data @> ?)",
            { group: true }.to_json
          )
        }

        # The same eligible public cohort is used by every board and private rank:
        # existing citizens, default included unless opted out, excluding groups,
        # blocked/deleted users and active organization staff/operator roles.
        scope :public_leaderboard_accounts, lambda {
          citizen_accounts.where(
            "EXISTS (SELECT 1 FROM decidim_users u WHERE u.id = decidim_bih_goodwill_accounts.owner_id " \
            "AND u.decidim_organization_id = decidim_bih_goodwill_accounts.decidim_organization_id " \
            "AND u.type = 'Decidim::User' AND u.deleted_at IS NULL AND u.blocked = FALSE " \
            "AND u.admin = FALSE AND u.managed = FALSE " \
            "AND NOT EXISTS (SELECT 1 FROM unnest(u.roles) AS user_role(role) WHERE role IS NOT NULL AND role !~ '^[[:space:]]*$') " \
            "AND LOWER(COALESCE(u.extended_data->>'bih_public_recognition','true')) NOT IN ('false','0','f','off','no') " \
            "AND NOT EXISTS (SELECT 1 FROM decidim_bih_operator_roles r WHERE r.decidim_user_id=u.id " \
            "AND r.decidim_organization_id=u.decidim_organization_id AND r.revoked_at IS NULL AND r.expires_at > ?))", Time.current
          )
        }

        # Kohorta za AUTOMATSKO izdavanje nagrade-praga: stvarni, samostalno
        # registrovani građani. Ogledalo public_leaderboard_accounts, ALI BEZ
        # klauzule o odustajanju od javnog priznanja — građanin koji ne želi biti
        # na javnoj tabli i dalje ima pravo na pozivnicu.
        scope :invitation_eligible_accounts, lambda {
          citizen_accounts.where(
            "NOT EXISTS (SELECT 1 FROM decidim_users u " \
            "WHERE u.id = decidim_bih_goodwill_accounts.owner_id " \
            "AND (u.admin = TRUE OR u.managed = TRUE " \
            "OR COALESCE(array_length(u.roles, 1), 0) > 0))"
          )
        }

        # The authoritative, host-free statement of "this user is staff/managed
        # and must NOT show on the PUBLIC recognition board". The
        # public_leaderboard_accounts SQL scope is the production mechanism; this
        # mirrors its rule in plain Ruby so the exclusion logic is unit-testable
        # without a database and so any caller that already has the User in hand
        # (e.g. a view filter) applies exactly the same rule. Groups are handled
        # separately by citizen_accounts and are not re-checked here.
        def self.excluded_from_public_leaderboard?(user)
          return true if user.nil?
          return true if user.respond_to?(:group?) && user.group?

          user.admin? ||
            (user.respond_to?(:managed?) && user.managed?) ||
            Array(user.roles).compact.any?(&:present?) ||
            (user.respond_to?(:blocked?) && user.blocked?) ||
            (user.respond_to?(:deleted?) && user.deleted?) ||
            Decidim::Bih::OperatorRole.active_for(user, user.organization).exists? ||
            !public_recognition_enabled_for?(user)
        end

        def self.public_recognition_enabled_for?(user)
          data = user.respond_to?(:extended_data) ? user.extended_data.to_h : {}
          return true unless data.has_key?("bih_public_recognition")

          value = data["bih_public_recognition"]
          return true if value.nil?
          !%w(false 0 f off no).include?(value.to_s.downcase)
        end

        # Recognition leaderboard: the top citizen accounts by contribution score
        # (sum of "earn" credits), organization-scoped, highest first. Returns
        # Account records each carrying a #score attribute. Recognition-only — it
        # never reflects gifting/redeeming, so being generous never costs rank.
        # PUBLIC board: organization staff / managed accounts are excluded via
        # public_leaderboard_accounts.
        def self.contribution_leaderboard(organization, limit: 25)
          public_leaderboard_accounts
            .where(decidim_organization_id: organization.id)
            .where("cached_contribution > 0")
            # Index-backed top-N off the cached column (no JOIN/GROUP/SUM), with a
            # deterministic id tiebreak for stable rank/pagination.
            .order(cached_contribution: :desc, id: :asc)
            .limit(limit)
        end

        # Time-windowed recognition leaderboard: the top citizen accounts by the
        # sum of "earn" credits booked SINCE +since+ (e.g. beginning_of_week /
        # beginning_of_month), organization-scoped, highest first. Unlike the
        # all-time board this aggregates live from the immutable ledger (there is
        # no per-window cache), filtering on the TRANSACTION's created_at (when
        # the points were earned). Each returned Account carries a virtual
        # #windowed_score; reuses public_leaderboard_accounts so the cohort
        # (groups + staff/managed excluded) matches the all-time board exactly.
        def self.contribution_leaderboard_since(organization, since:, limit: 25)
          scores = "SELECT account_id, SUM(amount) AS windowed_score FROM (#{ContributionProjection.sql}) recognition " \
                   "WHERE earned_at >= #{connection.quote(ContributionProjection.boundary(since))} GROUP BY account_id"
          public_leaderboard_accounts.where(decidim_organization_id: organization.id)
            .joins("JOIN (#{scores}) recognition ON recognition.account_id = decidim_bih_goodwill_accounts.id")
            .where("recognition.windowed_score > 0")
            .select("decidim_bih_goodwill_accounts.*, recognition.windowed_score")
            .order("recognition.windowed_score DESC, decidim_bih_goodwill_accounts.id ASC").limit(limit)
        end

        # The 1-based recognition rank of +account+ on the citizen leaderboard:
        # one plus the number of citizen accounts in the SAME organization with a
        # strictly higher contribution score. Mirrors contribution_leaderboard's
        # cohort (citizen-only, same org) so rank and board can never disagree.
        # Returns nil for a non-citizen (group) or owner-less/system account.
        def self.rank_for(account)
          return nil unless account&.kind == "user"
          return nil unless account.contribution_score.positive?
          cohort = public_leaderboard_accounts.where(decidim_organization_id: account.decidim_organization_id)
          return nil unless cohort.exists?(id: account.id)

          cohort.where("cached_contribution > :score OR (cached_contribution = :score AND id < :id)",
                       score: account.contribution_score, id: account.id).count + 1
        end

        # The spendable wallet balance for +user+ in +organization+, or 0 when
        # there is no user or no account yet. The single source of truth for the
        # "find the citizen's wallet and read its balance" lookup that the public
        # wallet/rewards/gifts/hub controllers all need. Owner resolution mirrors
        # Ledger#account_for (STI base class as the stored owner_type).
        def self.balance_for(user, organization)
          return 0 unless user

          find_by(
            organization:,
            owner_type: user.class.base_class.name,
            owner_id: user.id
          )&.balance || 0
        end

        # Spendable wallet = sum of all signed entries (served from the cache,
        # maintained in Ledger#build_and_save).
        def balance
          cached_balance
        end

        # Recognition score = source-period earnings plus signed corrections (cached);
        # unaffected by gift/redeem/adjustment.
        def contribution_score
          cached_contribution
        end

        # Authoritative recomputations from the immutable ledger — used by the
        # reconcile rake (decidim_bih:goodwill:reconcile) to verify the cache.
        def recomputed_balance
          entries.sum(:amount)
        end

        # Mirrors Ledger#contribution_credit_for exactly, both driven by
        # Transaction#contributes_to_score? / CONTRIBUTION_ADJUSTMENT_REASONS —
        # the single shared definition of "what counts toward contribution
        # score". Only ever non-zero for a "user" account (a "system" account
        # never accrues contribution, same as the writer). "earn" only ever
        # counts a positive amount (a real earn never debits the user side);
        # a contribution_adjustment? (currently only the 2026-09 rescale) counts
        # its full signed amount, so a rescale that LOWERS a score is correctly
        # recomputed too — this is what decidim_bih:goodwill:reconcile trusts,
        # so it must agree with the cache Ledger#build_and_save maintains or a
        # later reconcile run silently reverts the rescale.
        def recomputed_contribution
          ContributionProjection.score(self)
        end

        # The recognition level/title for this account's contribution score.
        def level
          Decidim::Bih::Goodwill::Levels.for(contribution_score)
        end

        private

        def system_account_has_no_owner
          return unless kind == "system"

          errors.add(:owner, :present) if owner_type.present? || owner_id.present?
        end

        def user_account_has_owner
          return unless kind == "user"

          errors.add(:owner, :blank) if owner_type.blank? || owner_id.blank?
        end
      end
    end
  end
end

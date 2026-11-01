# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # The catalog of symbolic rewards a citizen can redeem wallet points for.
      #
      # Round 25 — the catalog is now ADMIN-MANAGED in a DB table
      # (Decidim::Bih::Goodwill::Reward). When an organization has adopted
      # table-backed rewards, `.all(org)` returns those. Only a never-adopted catalog FALLS BACK
      # to the legacy host config list (Decidim::Bih.goodwill_rewards_catalog),
      # so nothing breaks before an operator imports/seeds the table.
      #
      # Both paths return objects exposing the SAME read interface
      # (key/cost/stock/expires_at + name/description/fulfillment/expired?/
      # remaining_stock(org)), so the public view, the redeem command, and the
      # admin fulfillment queue treat them identically. Kept deliberately
      # modest — recognition, not cash-equivalence (motivation crowding-out
      # research).
      module RewardsCatalog
        # stock: (Integer) — optional maximum number of concurrent open
        #   fulfillments. When nil the reward is unlimited.
        # expires_at: (Date / Time / nil) — optional hard cutoff after which
        #   the reward cannot be redeemed and existing open fulfillments may
        #   be auto-canceled by the rake task.
        Reward = Struct.new(:key, :cost, :stock, :expires_at, :deducts_points,
                            :auto_issue_at_threshold, keyword_init: true) do
          # Config nagrade su uvijek kupovina (skidaju bodove) i nikad se ne
          # izdaju automatski — nova ponašanja postoje samo u tabeli.
          def deducts_points? = deducts_points != false

          def auto_issue_at_threshold? = auto_issue_at_threshold == true

          def name
            I18n.t("decidim.bih.goodwill.rewards.#{key}", default: key.to_s.humanize)
          end

          def description
            optional_translation("reward_descriptions")
          end

          def fulfillment
            optional_translation("reward_fulfillment")
          end

          # Returns true when the reward has a hard deadline and it has passed.
          def expired?
            expires_at.present? && Time.current > expires_at
          end

          # Remaining available slots for redemption, given the current number
          # of consumed fulfillments (open OR fulfilled — both hold a slot).
          # canceled/reversed rows release their slot. Returns nil when stock
          # is uncapped.
          def remaining_stock(organization)
            return nil if stock.blank?

            consumed_count = Decidim::Bih::Goodwill::RewardFulfillment
                             .where(organization:, reward_key: key)
                             .where.not(status: %w(canceled reversed))
                             .count
            [stock - consumed_count, 0].max
          end

          private

          def optional_translation(scope)
            path = "decidim.bih.goodwill.#{scope}.#{key}"
            I18n.t(path) if I18n.exists?(path)
          end
        end

        module_function

        # Returns the catalog for an organization. Table-backed when the org has
        # active rewards; otherwise the legacy config list. `organization` may be
        # nil (legacy global callers) — that always uses config.
        def all(organization = nil)
          table_rewards = table_rewards_for(organization)
          return table_rewards if table_rewards

          config_rewards
        end

        # Finds a single reward by key, honouring the same table-vs-config
        # precedence as `.all`.
        def find(key, organization = nil)
          all(organization).find { |reward| reward.key == key.to_s }
        end

        def any?(organization = nil)
          all(organization).any?
        end

        # The catalog minus prag-nagrade (auto_issue_at_threshold). Those are
        # issued by the system alone on crossing a threshold — never offered
        # for a citizen's manual redeem click, and never listed as something
        # points are "spent" on. Use this wherever a reward LIST reaches a
        # citizen (the nagrade grid, the kako spend explainer); `.all`/`.find`
        # stay unfiltered because LaunchInvitation.reward_for resolves the
        # threshold reward BY KEY through them.
        def manually_redeemable(organization = nil)
          all(organization).reject(&:auto_issue_at_threshold?)
        end

        # Adoption is durable even when every DB reward is retired/deleted.
        # Closed means deliberately unavailable, never a legacy-config fallback.
        NAMESPACE = "goodwill_catalog"
        MODES = %w(managed closed).freeze

        def mode(organization)
          return "legacy" if organization.blank? || !table_available?

          stored = Setting.where(organization:, namespace: NAMESPACE, key: "mode").pick(:value)
          return stored if MODES.include?(stored)
          return "closed" unless stored.nil? # An invalid persisted mode must never reopen legacy rewards.
          return "managed" if Decidim::Bih::Goodwill::Reward.where(organization:).exists?

          "legacy"
        end

        def adopt!(organization)
          # Never reopen a closed catalogue as a side effect of a reward edit.
          organization.with_lock do
            return if mode(organization) == "closed"

            Setting.put(organization, NAMESPACE, "mode", "managed")
          end
        end

        def table_rewards_for(organization)
          case mode(organization)
          when "closed" then []
          when "managed" then Decidim::Bih::Goodwill::Reward.where(organization:).active.ordered.to_a
          end
        end

        # Builds the legacy config-driven catalog (Struct rewards).
        def config_rewards
          Array(Decidim::Bih.goodwill_rewards_catalog).filter_map do |row|
            row = row.symbolize_keys
            next if row[:key].blank?

            expires_raw = row[:expires_at]
            # A Date value expires at end-of-day in the application timezone so
            # that a reward listed as expiring "today" is still redeemable until
            # midnight. Time/DateTime values are used as-is (already precise).
            expires_at = if expires_raw.is_a?(Date) && !expires_raw.is_a?(Time)
                           Time.zone.parse(expires_raw.to_s)&.end_of_day
                         elsif expires_raw.present?
                           expires_raw.to_time
                         end

            Reward.new(
              key: row[:key].to_s,
              cost: row[:cost].to_i,
              stock: row[:stock]&.to_i,
              expires_at:,
              deducts_points: true,
              auto_issue_at_threshold: false
            )
          end
        end

        # Guards against querying the table before its migration has run (e.g.
        # during boot on a not-yet-migrated DB), in which case we transparently
        # fall back to config rather than raising.
        def table_available?
          Decidim::Bih::Goodwill::Reward.table_exists?
        end
      end
    end
  end
end

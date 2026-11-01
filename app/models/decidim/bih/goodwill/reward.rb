# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Round 25 — a table-backed, admin-managed catalog entry citizens can
      # redeem wallet points for. Replaces (with config fallback) the static
      # Decidim::Bih.goodwill_rewards_catalog list, so an operator can add,
      # edit, or retire a reward without a redeploy.
      #
      # title/description are jsonb i18n hashes keyed by locale code
      # (sr/sr-Cyrl/bs/hr/en). The public list and redeem flow consume rewards
      # through Decidim::Bih::Goodwill::RewardsCatalog, which maps both this
      # model and the legacy config Struct to the SAME read interface
      # (key/cost/stock/expires_at + name/description/fulfillment/expired?/
      # remaining_stock).
      class Reward < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_rewards"

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        belongs_to :sponsor_partner_profile,
                   class_name: "Decidim::Bih::PartnerProfile",
                   optional: true

        validates :key, presence: true,
                        uniqueness: { scope: :decidim_organization_id, case_sensitive: true }
        validates :cost, numericality: { only_integer: true, greater_than: 0 }
        validates :stock,
                  numericality: { only_integer: true, greater_than_or_equal_to: 0 },
                  allow_nil: true
        validate :key_is_immutable_after_redemption, on: :update
        validate :usable_invitation_matches_registration
        after_create :adopt_catalog!
        before_destroy :adopt_catalog!

        scope :active, -> { where(active: true) }
        scope :ordered, -> { order(cost: :asc, id: :asc) }

        # Rewards a citizen could actually redeem right now: active, in stock
        # (or uncapped), and not past their hard deadline. Mirrors the runtime
        # checks in RedeemReward so the public list and the command agree.
        # Note: `stock = 0` removes it; runtime remaining-stock (counting open
        # fulfillments) is still enforced in RedeemReward for finer-grained caps.
        scope :available, lambda {
          active
            .where("stock IS NULL OR stock > 0")
            .where("expires_at IS NULL OR expires_at > ?", Time.current)
        }

        # Localised display name for the current I18n.locale, falling back to
        # the first available translation, then the key — never blank, so the
        # admin list and public card always render something.
        def name
          translated(title).presence || key.to_s.humanize
        end

        # Optional localised description; nil (not "") when no translation
        # exists so the view's `if description.present?` guard works unchanged.
        def description
          translated(read_attribute(:description)).presence
        end

        # The legacy config rewards expose a separate `fulfillment` note from
        # i18n; the table-backed model has no equivalent column, so this returns
        # nil and the view's guard simply hides that line.
        def fulfillment
          nil
        end

        # True when the reward has a hard deadline and it has passed.
        def expired?
          expires_at.present? && Time.current > expires_at
        end

        # False znači: nagrada je PRAG, ne kupovina — dosegneš je i dobiješ je,
        # bodovi ostaju na računu. Postojeće nagrade su default true.
        def deducts_points? = deducts_points != false

        # True znači: izdaje se sama u trenutku prelaska praga, bez klika
        # građanina i bez ručne potvrde operatora.
        def auto_issue_at_threshold? = auto_issue_at_threshold == true

        # Remaining redeemable slots given current consumed fulfillments
        # (open OR fulfilled hold a slot; canceled/reversed release it). nil
        # when stock is uncapped. Matches RewardsCatalog::Reward#remaining_stock
        # so callers can treat both shapes identically.
        def remaining_stock(org = organization)
          return nil if stock.blank?

          consumed = Decidim::Bih::Goodwill::RewardFulfillment
                     .where(organization: org, reward_key: key)
                     .where.not(status: %w(canceled reversed))
                     .count
          [stock - consumed, 0].max
        end

        def key_locked?
          return false unless persisted?

          Decidim::Bih::Goodwill::RewardFulfillment.exists?(organization:, reward_key: key_in_database)
        end

        private

        def adopt_catalog!
          RewardsCatalog.adopt!(organization)
        end

        def usable_invitation_matches_registration
          return unless key == "pozivnica_lansiranje" && active? && auto_issue_at_threshold? && !expired?

          errors.add(:cost, :invalid) unless cost == 20
        end

        def key_is_immutable_after_redemption
          return unless will_save_change_to_key? && key_locked?

          errors.add(:key, :readonly)
        end

        # Resolves a locale-keyed jsonb hash for the current locale, falling
        # back to the base language (e.g. "sr" for "sr-Cyrl") then any value.
        def translated(hash)
          return nil if hash.blank?

          locale = I18n.locale.to_s
          hash[locale] ||
            hash[locale.split("-").first] ||
            hash.values.compact_blank.first
        end
      end
    end
  end
end

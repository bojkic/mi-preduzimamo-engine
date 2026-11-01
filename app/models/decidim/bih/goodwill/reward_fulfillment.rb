# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Manual fulfillment state for a redeemed reward. This is intentionally
      # mutable operational data; the associated ledger transaction remains the
      # immutable source of truth for the point spend.
      class RewardFulfillment < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_reward_fulfillments"
        # Rails 7.2's active_record.set_filter_attributes railtie snapshots
        # config.filter_parameters before this engine's initializer adds
        # :entry_code to it, so filter_attributes never picks it up
        # automatically. Set it explicitly so #inspect and debug-level AR
        # bind-parameter logging never print the raw one-time entry code.
        self.filter_attributes = ["entry_code"]

        STATUSES = %w(requested reserved fulfilled canceled reversed).freeze
        OPEN_STATUSES = %w(requested reserved).freeze
        REQUEST_KEY_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        belongs_to :ledger_transaction,
                   class_name: "Decidim::Bih::Goodwill::Transaction",
                   foreign_key: "decidim_bih_goodwill_transaction_id",
                   inverse_of: :reward_fulfillment,
                   optional: true

        belongs_to :user,
                   class_name: "Decidim::User",
                   foreign_key: "decidim_user_id"

        belongs_to :handled_by,
                   class_name: "Decidim::User",
                   optional: true

        has_many :events,
                 class_name: "Decidim::Bih::Goodwill::RewardFulfillmentEvent",
                 foreign_key: "decidim_bih_goodwill_reward_fulfillment_id",
                 inverse_of: :fulfillment,
                 dependent: :restrict_with_exception

        validates :reward_key, presence: true
        validates :request_key,
                  format: { with: REQUEST_KEY_PATTERN },
                  uniqueness: { scope: [:decidim_organization_id, :decidim_user_id] },
                  allow_nil: true
        validates :status, presence: true, inclusion: { in: STATUSES }
        validates :cost, numericality: { only_integer: true, greater_than: 0 }

        # Ručno preuzimanje MORA imati transakciju — to je nepromjenjivi trag
        # potrošnje bodova. Samo automatski izdata nagrada-prag smije biti bez
        # nje, jer se tamo bodovi i ne skidaju. Pravilo ide U OBA SMJERA:
        # automatski izdata pozivnica ne smije NIKAD nositi transakciju — to bi
        # bila proturječnost "bodovi se ne skidaju" sa priloženom transakcijom
        # skidanja bodova.
        validates :ledger_transaction, presence: true, unless: :auto_issued?
        validates :ledger_transaction, absence: true, if: :auto_issued?

        scope :open, -> { where(status: OPEN_STATUSES) }
        scope :recent, -> { order(created_at: :desc, id: :desc) }
        # Fulfillments whose reward expired 7+ days ago and are still open —
        # candidates for the cancel_expired_fulfillments rake task.
        scope :cancelable_expired, lambda {
          open.where("reward_expires_at IS NOT NULL AND reward_expires_at < ?", 7.days.ago)
        }

        def open?
          OPEN_STATUSES.include?(status)
        end

        def certificate_available?
          reward_key == "zahvalnica" && %w(requested reserved fulfilled).include?(status) && ledger_transaction.present?
        end

        def citizen_cancelable?
          status == "requested"
        end

        def mark!(new_status, by:, source: nil, actor_role: nil, metadata: {})
          new_status = new_status.to_s
          return false unless STATUSES.include?(new_status)

          with_lock do
            return false if status == new_status
            return false if %w(fulfilled canceled reversed).include?(status) && new_status != "reversed"

            previous_status = status
            update!(status: new_status, handled_by: by, handled_at: Time.current)
            record_event!(new_status, actor: by, source:, actor_role:,
                          metadata: event_metadata(previous_status, new_status).merge(metadata.to_h))
          end
          true
        end

        def record_event!(event_type, actor: nil, source: nil, actor_role: nil, metadata: {})
          return unless RewardFulfillmentEvent.available?

          events.create!(
            event_type: event_type.to_s,
            actor:,
            source:,
            actor_role:,
            metadata: RewardFulfillmentEvent.sanitize_metadata(metadata)
          )
        end

        private

        def event_metadata(previous_status, new_status)
          {
            from_status: previous_status,
            to_status: new_status,
            reward_key:,
            cost:,
            ledger_transaction_id: decidim_bih_goodwill_transaction_id
          }
        end
      end
    end
  end
end

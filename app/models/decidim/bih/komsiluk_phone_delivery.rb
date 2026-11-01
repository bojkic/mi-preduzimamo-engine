# frozen_string_literal: true

module Decidim
  module Bih
    # One phone chain per publication/recipient. A committed claim never retries
    # an ambiguous provider request; its IDs are reconciled independently.
    class KomsilukPhoneDelivery < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_komsiluk_phone_deliveries"
      self.filter_attributes += [:destination_digest, :provider_message_ids, :previous_attempts]
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id
      belongs_to :send_intent, class_name: "Decidim::Bih::KomsilukSendIntent"
      belongs_to :platform_delivery, class_name: "Decidim::Bih::PlatformDelivery"
      validates :status, inclusion: { in: %w(pending sending accepted delivered rejected failed unknown skipped) }
      validates :due_at, :expires_at, :destination_digest, presence: true
      after_create_commit :enqueue

      def enqueue
        KomsilukPhoneDeliveryJob.set(wait_until: due_at).perform_later(id)
      rescue StandardError => e
        Rails.logger.warn("[komsiluk_delivery] enqueue deferred #{e.class}")
      end
    end
  end
end

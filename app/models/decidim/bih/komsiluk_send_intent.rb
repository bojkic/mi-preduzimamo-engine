# frozen_string_literal: true

module Decidim
  module Bih
    # Exact operator preview. Encrypted content is never a general member list.
    class KomsilukSendIntent < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_komsiluk_send_intents"
      self.filter_attributes += [:payload_ciphertext]
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :actor, class_name: "Decidim::User", foreign_key: :decidim_user_id
      # Provider evidence is removed only by the scoped terminal-data sweep.
      has_many :deliveries, class_name: "Decidim::Bih::KomsilukPhoneDelivery", foreign_key: :send_intent_id, dependent: :restrict_with_exception
      validates :kind, inclusion: { in: %w(publication phone correction) }
      validates :state, inclusion: { in: %w(preview confirmed cancelled expired) }
      validates :publication_key, :preview_digest, :expires_at, presence: true
      validates :payload_ciphertext, presence: true, unless: :payload_scrubbed_at?

      def payload
        return {} if payload_scrubbed_at

        Infobip::EncryptedJobEnvelope.open(payload_ciphertext, purpose: "komsiluk-send", salt: "bih-komsiluk-send-v1").deep_symbolize_keys
      end

      def payload=(value)
        self.payload_ciphertext = Infobip::EncryptedJobEnvelope.seal(value, purpose: "komsiluk-send", salt: "bih-komsiluk-send-v1")
      end

      def phone_payload
        payload[:phone] || payload
      end

      def confirmation_token
        signed_id(purpose: :komsiluk_send_confirmation, expires_in: [expires_at - Time.current, 1].max)
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # One logical message, independent of how many attempts it takes.
      #
      # Chosen over extending AccountNotification because that table is one
      # intent AND one attempt at once, requires an account, and holds a
      # purpose-bound encrypted payload for optional external copies only. An
      # intent can address a recipient with no account, can own several attempts
      # (per-device push is several real deliveries of one message), and stores
      # no payload at all — authentication secrets, magic links, report tokens
      # and push endpoints are never duplicated here.
      #
      # The existing record is referenced, not replaced: a legacy
      # AccountNotification keeps its meaning and its callers.
      class Intent < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_messaging_intents"

        # Phase 1 is shadow only. `compatibility` and `target` exist so the
        # column does not have to change when Phase 2 enrols a sender, but an
        # intent can never describe itself as the authority for a real send.
        MODES = %w(shadow compatibility target).freeze
        STATUSES = %w(planned evaluated recorded superseded).freeze

        belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
        belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id, optional: true
        belongs_to :account_notification, class_name: "Decidim::Bih::AccountNotification",
                                          foreign_key: :decidim_bih_account_notification_id, optional: true
        has_many :attempts, class_name: "Decidim::Bih::Messaging::Attempt", inverse_of: :intent, dependent: :destroy

        validates :message_class, :correlation_key, :deduplication_scope, :policy_version,
                  :eligibility_version, presence: true
        validates :recipient_kind, inclusion: { in: RecipientContext::KINDS }
        validates :mode, inclusion: { in: MODES }
        validates :status, inclusion: { in: STATUSES }
        validate :known_message_class
        validate :account_recipient_has_an_account

        private

        def known_message_class
          return if message_class.blank?
          return if MessageClass.known?(message_class)

          errors.add(:message_class, :inclusion)
        end

        # An account-addressed intent without an account would be a fabricated
        # recipient; an anonymous one WITH an account would be a silent match.
        def account_recipient_has_an_account
          if %w(account staff).include?(recipient_kind)
            errors.add(:decidim_user_id, :blank) if decidim_user_id.nil?
          elsif !decidim_user_id.nil?
            errors.add(:decidim_user_id, :present)
          end
        end
      end
    end
  end
end

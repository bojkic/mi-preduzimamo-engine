# frozen_string_literal: true

module Decidim
  module Bih
    module ClearsChannelConnections
      extend ActiveSupport::Concern

      included do
        after_update :clear_private_channel_connections, if: -> { saved_change_to_deleted_at? && deleted_at.present? }
        before_destroy :clear_private_channel_connections
      end

      private

      def clear_private_channel_connections
        Decidim::Bih::AccountNotification.where(decidim_user_id: id).delete_all
        Decidim::Bih::ChannelConnection.where(decidim_user_id: id).delete_all
        Decidim::Bih::ChannelConnectionChallenge.where(decidim_user_id: id).delete_all
        redact_messaging_destinations
      end

      # An immutable operational event is REDACTED, not erased.
      #
      # Deleting the attempt rows would destroy the record that a platform sent
      # somebody something — which is exactly the record a person exercising
      # their rights may need, and exactly the record an auditor needs. Keeping
      # the destination digest would leave a stable identifier that still points
      # at them. So the row survives with its channel, status, reason and
      # timestamps, and the pointer to a destination goes.
      #
      # Decidim's account deletion is a SOFT delete: it sets deleted_at and
      # leaves the user row, so the database's own on_delete rules never fire.
      # This callback is the only thing that runs.
      def redact_messaging_destinations
        intents = Decidim::Bih::Messaging::Intent.where(decidim_user_id: id).select(:id)
        Decidim::Bih::Messaging::Attempt
          .where(intent_id: intents)
          .where.not(destination_digest: nil)
          .update_all(destination_kind: Decidim::Bih::Messaging::Attempt::REDACTED_KIND, # rubocop:disable Rails/SkipsModelValidations
                      destination_digest: nil, updated_at: Time.current)
      end
    end
  end
end

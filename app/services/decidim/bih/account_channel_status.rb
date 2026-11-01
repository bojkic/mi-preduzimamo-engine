# frozen_string_literal: true

module Decidim
  module Bih
    # Private display data: never returns phone numbers or external messaging IDs.
    class AccountChannelStatus
      TOPICS = %w(report_updates community_news city_service_alerts).freeze
      CHANNELS = %w(viber whatsapp messenger instagram).freeze

      # Why a channel cannot carry a message, in the vocabulary the settings
      # page can translate (Messaging::EffectiveSetting::REASON_KEYS). A state
      # with no entry here would render as a switch the citizen cannot act on
      # and cannot understand, so the pure test asserts the two lists agree.
      STATE_REASONS = {
        "verified_phone" => nil,
        "connected" => nil,
        "phone_missing" => "no_verified_phone",
        "not_connected" => "no_connected_channel",
        "session_closed" => "session_expired",
        "unavailable" => "channel_not_configured"
      }.freeze

      def self.reason_for(state)
        STATE_REASONS[state.to_s]
      end

      def self.for(user:, organization:)
        return [] unless user && organization && user.decidim_organization_id == organization.id

        new(user: user, organization: organization).rows
      end

      def initialize(user:, organization:)
        @user = user
        @organization = organization
        @client = Infobip::Client.new
      end

      def rows
        phone = VerifiedPhone.phone_for(user: @user, organization: @organization)
        CHANNELS.map do |channel|
          state = %w(viber whatsapp).include?(channel) ? phone_state(channel, phone) : social_state(channel)
          { channel: channel, state: state, reason: self.class.reason_for(state) }
        end
      end

      private

      def phone_state(channel, phone)
        available = channel == "viber" ? @client.viber_business_configured? : @client.configured? && Config.infobip[:whatsapp_sender].present?
        return "unavailable" unless available

        phone.present? ? "verified_phone" : "phone_missing"
      end

      def social_state(channel)
        return "unavailable" if ChannelConnections.configured_sender(channel).blank?

        connection = ChannelConnections.for_user(user: @user, organization: @organization, channel: channel)
        return "not_connected" unless connection

        connection.session_expires_at && connection.session_expires_at > Time.current ? "connected" : "session_closed"
      end
    end
  end
end

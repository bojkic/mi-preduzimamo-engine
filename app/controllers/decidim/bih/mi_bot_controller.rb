# frozen_string_literal: true

require "uri"

module Decidim
  module Bih
    # Public, anonymous introduction to the configured civic assistant. Like the
    # other engine surfaces it inherits from
    # Decidim::ApplicationController so it gets current_organization (from the
    # request host) and the Decidim public layout without an authenticated user.
    #
    # The page exposes the one in-site assistant and, only when launch readiness
    # enables it, the connected Viber entry. Unavailable channels are not shown.
    #
    # GET /mi-bot
    class MiBotController < Decidim::ApplicationController
      EXTERNAL_CHAT_CHANNELS = %w(whatsapp messenger instagram).freeze

      helper Decidim::Bih::MiBotIconsHelper

      def show
        @viber_onboarding_enabled = viber_onboarding_enabled?
        @viber_onboarding_url = viber_onboarding_url if @viber_onboarding_enabled
        @viber_business_onboarding_enabled = Decidim::Bih::ViberBusinessPublicOnboarding.available?(current_organization)
        @external_chat_onboarding_links = external_chat_onboarding_links
      end

      private

      def viber_onboarding_enabled?
        Decidim::Bih.viber_public_onboarding_enabled &&
          Decidim::Bih.viber_bot_uri.to_s.strip.present? &&
          Decidim::Bih::Infobip::Client.new.viber_bot_active? &&
          Decidim::Bih::Config.viber_webhook_configured? &&
          current_launch_approval?("viber_launch")
      end

      def viber_onboarding_url
        "viber://pa?chatURI=#{ERB::Util.url_encode(Decidim::Bih.viber_bot_uri.to_s.strip)}"
      end

      def external_chat_onboarding_links
        configured_links = Decidim::Bih.external_chat_onboarding_links.to_h.stringify_keys
        client = Decidim::Bih::Infobip::Client.new

        links = EXTERNAL_CHAT_CHANNELS.filter_map do |channel|
          next unless configured_links.has_key?(channel)

          url = safe_external_chat_url(configured_links[channel])
          return [] if url.nil? || !client.chat_channel_configured?(channel)

          { channel:, url: }
        end
        return [] unless external_chat_launch_approved?(links.pluck(:channel))

        links
      end

      def current_launch_approval?(kind)
        Decidim::Bih::GovernanceApproval.current_for(current_organization, kind).present?
      end

      def external_chat_launch_approved?(channels)
        return false if channels.empty?

        approval = Decidim::Bih::GovernanceApproval.current_for(current_organization, "external_chat_launch")
        approval&.scope_key == Decidim::Bih::GovernanceApproval.external_chat_scope_key(channels)
      end

      def safe_external_chat_url(value)
        uri = URI.parse(value.to_s.strip)
        return unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?

        uri.to_s
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end

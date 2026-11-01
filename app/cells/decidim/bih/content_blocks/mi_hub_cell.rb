# frozen_string_literal: true

require "uri"

module Decidim
  module Bih
    module ContentBlocks
      # Homepage "MI hub" content block: the branded "MI <verb>" module tiles
      # plus the omnichannel chatbot band, straight from the MI PRE(D)UZIMAMO!
      # design kit. Data-light — copy comes from i18n (decidim.bih.content_blocks.mi_hub.*),
      # styling from the host theme (public/mi/mi-theme.css: .mi-modules / .mi-omni-band).
      class MiHubCell < Decidim::ViewModel
        include Decidim::SanitizeHelper

        EXTERNAL_CHAT_CHANNELS = %w(whatsapp messenger instagram).freeze

        delegate :current_organization, to: :controller

        # The "MI <verb>" tiles, each mapped to a LIVE destination. accent drives
        # the per-module colour strip + icon tile (sava/park/coral/sun).
        #
        # Engine route helpers are not guaranteed on the cell helper surface, so
        # use Decidim::Bih.public_path to keep second-host mount paths configurable.
        def tiles
          [
            {
              key: "prijavljujemo",
              accent: "coral",
              icon: "map-pin-line",
              href: Decidim::Bih.public_path,
              secondary_href: Decidim::Bih.public_path("mapa")
            },
            {
              key: "odlucujemo",
              accent: "sava",
              icon: "discuss-line",
              href: decision_path
            },
            {
              key: "biramo",
              accent: "sun",
              icon: "heart-line",
              href: Decidim::Bih.public_path("projekti")
            },
            {
              key: "predlazemo",
              accent: "park",
              icon: "lightbulb-line",
              href: processes_path
            },
            {
              key: "vrijednujemo",
              accent: "sun",
              icon: "copper-coin-line",
              href: Decidim::Bih.public_path("zajednistvo")
            },
            {
              key: "volontiramo",
              accent: "park",
              icon: "shield-check-line",
              href: Decidim::Bih.public_path("volontiranje")
            },
            {
              key: "druzimo_se",
              accent: "coral",
              icon: "chat-3-line",
              href: Decidim::Bih.public_path("komsiluk-board")
            }
          ]
        end

        # Public channel pills for the navy band. The website is always
        # available; provider channels appear only after both delivery and the
        # host-owned public entry gate are ready. SMS is outbound-only and is
        # deliberately never presented as a citizen-chat channel.
        def channels
          ["web", *viber_channel, *external_chat_channels]
        end

        def t_scope(key)
          t(key, scope: "decidim.bih.content_blocks.mi_hub")
        end

        def heart_mark_path
          "/mi/heart-mark.webp"
        end

        def persona_image_path
          Decidim::Bih.mi_bot_persona_image_path.to_s.presence
        end

        def persona_static_image_path
          Decidim::Bih.mi_bot_persona_static_image_path.to_s.presence || persona_image_path
        end

        private

        def decision_path
          configured = Decidim::Bih.mi_hub_decision_path.to_s.strip
          return configured unless configured.empty?

          processes_path
        end

        def processes_path
          "/processes"
        end

        def viber_channel
          return ["viber"] if Decidim::Bih::ViberBusinessPublicOnboarding.available?(current_organization)

          return [] unless Decidim::Bih.viber_public_onboarding_enabled
          return [] if Decidim::Bih.viber_bot_uri.to_s.strip.empty?
          return [] unless Decidim::Bih::Infobip::Client.new.viber_bot_active?
          return [] unless Decidim::Bih::Config.viber_webhook_configured?
          return [] unless current_launch_approval?("viber_launch")

          ["viber"]
        end

        def external_chat_channels
          links = Decidim::Bih.external_chat_onboarding_links.to_h.stringify_keys
          client = Decidim::Bih::Infobip::Client.new

          channels = EXTERNAL_CHAT_CHANNELS.filter_map do |channel|
            next unless links.has_key?(channel)
            return [] unless safe_external_chat_url?(links[channel]) && client.chat_channel_configured?(channel)

            channel
          end
          return [] unless external_chat_launch_approved?(channels)

          channels
        end

        def current_launch_approval?(kind)
          Decidim::Bih::GovernanceApproval.current_for(current_organization, kind).present?
        end

        def external_chat_launch_approved?(channels)
          return false if channels.empty?

          approval = Decidim::Bih::GovernanceApproval.current_for(current_organization, "external_chat_launch")
          approval&.scope_key == Decidim::Bih::GovernanceApproval.external_chat_scope_key(channels)
        end

        def safe_external_chat_url?(value)
          uri = URI.parse(value.to_s.strip)
          uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
        rescue URI::InvalidURIError
          false
        end
      end
    end
  end
end

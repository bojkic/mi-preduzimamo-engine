# frozen_string_literal: true

module Decidim
  module Bih
    # Public visibility for the MSISDN-addressed Business Messages conversation.
    # This is separate from the Viber Bot deep link and its launch switch.
    module ViberBusinessPublicOnboarding
      FLAG = "DECIDIM_BIH_VIBER_BM_PUBLIC_ONBOARDING_ENABLED"

      module_function

      def available?(_organization)
        return false unless ENV.fetch(FLAG, "false").match?(/\A(true|1|yes|on)\z/i)
        secret = ENV.fetch("VIBER_BM_WEBHOOK_SECRET", nil).to_s.presence ||
                 ENV.fetch("INFOBIP_CHAT_WEBHOOK_SECRET", "").to_s
        return false unless secret.length >= 16
        Decidim::Bih::Infobip::Client.new.chat_channel_configured?("viber_bm")
      end
    end
  end
end

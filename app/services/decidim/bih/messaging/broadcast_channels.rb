# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # The operator enables proactive delivery once. Provider readiness limits
      # eligible candidates; a Viber launch approval applies only to Viber.
      module BroadcastChannels
        module_function

        def for(organization)
          client = Infobip::Client.new
          config = Config.infobip
          channels = ["email"]
          %w(messenger instagram).each { |channel| channels << channel if client.chat_channel_configured?(channel) }
          channels << "whatsapp" if client.configured? && config[:messages_api_enabled] && config[:whatsapp_sender].present?
          if client.viber_business_configured? && !IntegrationHealth.instance.send_blocked?(provider: "infobip") &&
             GovernanceApproval.current_for(organization, "viber_launch").present?
            channels << "viber"
          end
          channels
        end
      end
    end
  end
end

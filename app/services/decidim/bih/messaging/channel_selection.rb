# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Eligibility and content fit are decided by the caller first. Among
      # equally suitable transports, linked live sessions avoid paid templates;
      # otherwise one provider-managed Viber/WhatsApp fallback request is used.
      module ChannelSelection
        SOCIAL = %w(messenger instagram).freeze
        PHONE = %w(viber whatsapp).freeze

        module_function

        def external(candidates)
          candidates = Array(candidates).map(&:to_s)
          session = SOCIAL.find { |channel| candidates.include?(channel) }
          return [session] if session
          return ["email"] if candidates.include?("email")

          PHONE & candidates
        end
      end
    end
  end
end

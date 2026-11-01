# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # In-app bell notification fired when an admin marks a reward fulfillment
      # as "reserved" (stock/seat/coupon is held for the citizen).
      #
      # IN-APP ONLY — no email, Viber, pickup notes, operator identity, provider
      # data or free text. The extra payload carries:
      #   reward_name: human-readable reward name
      #   fulfillment: optional catalog fulfillment text
      class RewardReservedEvent < Decidim::Events::BaseEvent
        include Decidim::Events::NotificationEvent

        def notification_title
          instructions = extra["fulfillment"].to_s.presence
          key = instructions ? "notification_title_with_instructions" : "notification_title"
          ActionController::Base.helpers.sanitize(
            I18n.t(
              "decidim.bih.goodwill.events.reward_reserved.#{key}",
              reward: extra["reward_name"].to_s,
              instructions:
            )
          ).html_safe
        end

        def resource_path = nil

        def resource_url = nil

        def resource_title = nil
      end
    end
  end
end

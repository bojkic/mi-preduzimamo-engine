# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # In-app bell notification fired when an admin marks a reward fulfillment
      # as "fulfilled" (the item has been handed to the citizen). Shows in the
      # notification center with the reward name.
      #
      # IN-APP ONLY (mirrors PointsEarnedEvent — NotificationEvent only, no
      # email). The extra payload carries:
      #   reward_name:   human-readable reward name
      #   fulfillment:   optional pickup instructions (folded into title via
      #                  locale key if present — locale values are safe)
      class RewardFulfilledEvent < Decidim::Events::BaseEvent
        include Decidim::Events::NotificationEvent

        # Pickup instructions come from locale keys (not user-controlled), so
        # interpolating them into the title is safe after sanitize. The
        # reward_name value is operator-configured and also sanitized.
        def notification_title
          instructions = extra["fulfillment"].to_s.presence
          key = instructions ? "notification_title_with_instructions" : "notification_title"
          ActionController::Base.helpers.sanitize(
            I18n.t(
              "decidim.bih.goodwill.events.reward_fulfilled.#{key}",
              reward: extra["reward_name"].to_s,
              instructions:
            )
          ).html_safe
        end

        # Non-clickable — the reward page is not a resource with a path.
        def resource_path = nil

        def resource_url = nil

        def resource_title = nil
      end
    end
  end
end

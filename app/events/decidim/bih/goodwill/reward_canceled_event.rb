# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # In-app bell notification fired when an admin cancels a reward
      # fulfillment (with point reversal). The citizen is informed that their
      # points have been refunded.
      #
      # IN-APP ONLY — mirrors RewardFulfilledEvent (NotificationEvent only).
      # extra payload:
      #   reward_name: human-readable reward name
      #   refunded:    integer amount refunded to the wallet
      class RewardCanceledEvent < Decidim::Events::BaseEvent
        include Decidim::Events::NotificationEvent

        def notification_title
          ActionController::Base.helpers.sanitize(
            I18n.t(
              "decidim.bih.goodwill.events.reward_canceled.notification_title",
              reward: extra["reward_name"].to_s,
              refunded: extra["refunded"].to_i
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

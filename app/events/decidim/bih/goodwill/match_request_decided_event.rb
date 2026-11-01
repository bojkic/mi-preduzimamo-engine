# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # In-app bell notification fired when an admin approves or rejects a
      # matched-giving request. Notifies the request owner (the group or user
      # whose request was decided).
      #
      # IN-APP ONLY — mirrors RewardCanceledEvent (NotificationEvent only, no
      # email). The extra payload carries:
      #   decision: "approved" | "rejected"
      #   points:   integer — the points amount on the request
      class MatchRequestDecidedEvent < Decidim::Events::BaseEvent
        include Decidim::Events::NotificationEvent

        def notification_title
          ActionController::Base.helpers.sanitize(
            I18n.t(
              "decidim.bih.goodwill.events.match_request_decided.notification_title_#{decision}",
              points: extra["points"].to_i
            )
          ).html_safe
        end

        def resource_path = nil

        def resource_url = nil

        def resource_title = nil

        private

        def decision
          extra["decision"].to_s
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # PII-light transition notification for project, need, and offer workflows.
    class CommunityContributionEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        ActionController::Base.helpers.sanitize(
          I18n.t(
            "decidim.bih.community_contribution_events.#{extra.fetch("transition")}",
            item: extra.fetch("item")
          )
        ).html_safe
      end

      def resource_path = extra["path"].presence

      def resource_url = nil

      def resource_title = extra["item"].to_s
    end
  end
end

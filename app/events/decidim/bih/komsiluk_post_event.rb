# frozen_string_literal: true

module Decidim
  module Bih
    # In-app notification for a published Komšiluk notice of any category.
    #
    # IN-APP ONLY (NotificationEvent, no email, no Viber).
    #
    # PRIVACY: the title is generic — it names the category but NEVER the author
    # or any other komšiluk member. The board URL is passed as `extra["board_url"]`
    # so recipients can navigate there; no individual author identity is exposed.
    class KomsilukPostEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        # An explicit publication marker distinguishes material corrections from
        # minor edits that only refresh the original receipt's content revision.
        title_key = extra["notice_update"] == true ? "updated_notification_title" : "notification_title"
        I18n.t(
          "decidim.bih.komsiluk_post.events.#{title_key}",
          category: category_label
        )
      end

      # New notices link to the membership-guarded publication; legacy queued
      # notifications retain their original board URL.
      def resource_path
        extra["board_url"].to_s.presence
      end

      def resource_url
        extra["board_url"].to_s.presence
      end

      def resource_title
        I18n.t("decidim.bih.komsiluk_post.events.resource_title")
      end

      private

      def category_label
        cat = extra["category"].to_s
        I18n.t("decidim.bih.komsiluk_board.categories.#{cat}", default: cat)
      end
    end
  end
end

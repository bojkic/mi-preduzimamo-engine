# frozen_string_literal: true

module Decidim
  module Bih
    class KomsilukHelpEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        I18n.t("decidim.bih.boards.help.notification")
      end

      def resource_path = extra["board_url"].to_s

      def resource_url = resource_path

      def resource_title = I18n.t("decidim.bih.komsiluk_board.index.title")
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Old bookmarks and forms now lead to the topic settings. Obsolete writes
    # cannot recreate channel cells or disable the platform inbox.
    module NotificationsSettingsNavigationOverride
      def show
        redirect_to Decidim::Bih.public_path("moj-nalog/poruke")
      end

      def update
        redirect_to Decidim::Bih.public_path("moj-nalog/poruke"), status: :see_other,
                                                                  alert: I18n.t("decidim.bih.communication_settings.screen_changed")
      end
    end
  end
end

Decidim::NotificationsSettingsController.prepend(Decidim::Bih::NotificationsSettingsNavigationOverride)

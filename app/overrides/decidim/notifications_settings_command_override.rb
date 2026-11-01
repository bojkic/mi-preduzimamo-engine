# frozen_string_literal: true

module Decidim
  module Bih
    # Core's removed preference dimensions are no longer a public writer.
    # Account privacy/staff choices have their own scoped account action.
    module NotificationsSettingsCommandOverride
      def call
        broadcast(:invalid)
      end
    end
  end
end

Decidim::UpdateNotificationsSettings.prepend(Decidim::Bih::NotificationsSettingsCommandOverride)

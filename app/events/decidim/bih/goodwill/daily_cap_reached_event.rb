# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Neutralna obavijest u zvonu kad je dnevna granica bodova za jednu radnju
      # dostignuta. Radnja se NIKAD ne blokira — lajk se upisuje, komentar se
      # objavljuje; samo ne nosi bodove.
      #
      # SAMO U APLIKACIJI (bez e-maila): kao i PointsEarnedEvent, ovo je
      # priznanje/informacija, ne razlog za punjenje sandučeta.
      class DailyCapReachedEvent < Decidim::Events::BaseEvent
        include Decidim::Events::NotificationEvent

        def notification_title
          ActionController::Base.helpers.sanitize(
            I18n.t(
              extra["period"] == "month" ? "decidim.bih.goodwill.cap_reached.notification_title" : "decidim.bih.goodwill.events.daily_cap_reached.notification_title",
              action: action_label, period: I18n.t("decidim.bih.goodwill.periods.#{extra['period'] || 'day'}", default: extra["period"] || "day"),
              reset_at: extra["reset_at"], default: "%{action}: limit reached (%{period}); resets %{reset_at}."
            )
          ).html_safe
        end

        def resource_path = nil

        def resource_url = nil

        def resource_title = nil

        private

        # Ljudska oznaka radnje, npr. "Sviđanje". Pada na sirovi ključ da naslov
        # nikad ne pukne.
        def action_label
          reason = extra["reason"].to_s
          I18n.t("decidim.bih.goodwill.actions.#{reason}", default: reason)
        end
      end
    end
  end
end

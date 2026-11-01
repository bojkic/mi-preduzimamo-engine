# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      # Private bell receipt; contains no report contact or public author activity.
      class CreditCorrectedEvent < Decidim::Events::BaseEvent
        include Decidim::Events::NotificationEvent
        def notification_title
          text = if extra["phase"] == "wallet_settled"
                   I18n.t("decidim.bih.goodwill.correction.wallet_settled", amount: extra["wallet_delta"].to_i.abs,
                     default: "Admin review completed: %{amount} points recovered from the wallet.")
                 else
                   I18n.t("decidim.bih.goodwill.correction.body", old_points: extra["old_points"],
                     new_points: extra["new_points"], delta: extra["delta"], default: "Contribution corrected: %{old_points} → %{new_points} (%{delta}).")
                 end
          if extra["status"] == "admin_pending"
            text += " " + I18n.t("decidim.bih.goodwill.correction.admin_pending", default: "Wallet recovery awaits admin review.")
          end
          if extra["phase"] != "wallet_settled" && extra["old_level"] != extra["new_level"]
            text += " " + I18n.t("decidim.bih.goodwill.correction.level_change", old_level: extra["old_level"],
              new_level: extra["new_level"], default: "Level: %{old_level} → %{new_level}.")
          end
          text = "#{extra["report_reference"]}: #{text}" if extra["report_reference"].present?
          ActionController::Base.helpers.sanitize(text).html_safe
        end
        def resource_path = nil
        def resource_url = nil
        def resource_title = nil
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # In-app notification fired when a citizen EARNS goodwill points. It shows
      # up in the Decidim notifications bell as "+<amount> — <action label>".
      #
      # IN-APP ONLY (no email): we mix in only Decidim::Events::NotificationEvent,
      # not the full SimpleEvent — earning a few points should never spam an
      # inbox; recognition is surfaced in the bell. The earn path stays fast and
      # the notification can never trigger a mailer.
      #
      # The notification title is built ENTIRELY from the +extra+ payload
      # (amount + action reason). When the caller supplies a +resource_gid+ in
      # extra, the notification bell item becomes a clickable deep link to the
      # source resource. Falls back to nil (non-clickable) when absent or
      # unresolvable, so old notifications and actions without a natural link
      # remain safe.
      class PointsEarnedEvent < Decidim::Events::BaseEvent
        include Decidim::Events::NotificationEvent

        # The notifications cell calls exactly this. Built from +extra+ only.
        # When +resource_path+ is available, the action label is wrapped in an
        # anchor tag so the bell item is a deep link to the source resource.
        # The sanitize allowlist permits <a href> and <strong>, so the markup
        # passes through intact. The action label comes from locales (not
        # user-controlled), and the path comes from ResourceLocatorPresenter,
        # so there is nothing user-controlled to escape here.
        def notification_title
          path = resource_path
          action_html = if path.present?
                          "<a href=\"#{path}\">#{action_label}</a>"
                        else
                          action_label
                        end

          ActionController::Base.helpers.sanitize(
            I18n.t(
              "decidim.bih.goodwill.events.points_earned.notification_title",
              amount: amount,
              action: action_html
            )
          ).html_safe
        end

        # Resolve the source resource URL from the GlobalID stored in extra.
        # Returns nil (non-clickable bell item) when no GID is present or the
        # resource no longer exists. Never raises — a bad GID must not blow up
        # the notifications cell render.
        def resource_path
          resolve_resource_path
        rescue StandardError
          nil
        end

        def resource_url
          resolve_resource_url
        rescue StandardError
          nil
        end

        # Keep the title nil — the notification_title carries all context.
        def resource_title = nil

        private

        def amount
          extra["amount"].to_i
        end

        # Human label for the earned action, e.g. "Volonterski sat". Falls back to
        # the raw reason when the key is missing so the title never blows up.
        def action_label
          reason = extra["reason"].to_s
          I18n.t(
            "decidim.bih.goodwill.actions.#{reason}",
            default: reason.presence || I18n.t("decidim.bih.goodwill.events.points_earned.default_action")
          )
        end

        # Locate the source resource from the GlobalID in extra[:resource_gid].
        # Returns nil when absent, invalid, or deleted. Memoized so that
        # notification_title and resource_path/resource_url share one DB lookup.
        def source_resource
          return @source_resource if defined?(@source_resource)

          @source_resource = begin
            return nil if extra["resource_gid"].blank?

            GlobalID::Locator.locate(extra["resource_gid"])
          rescue StandardError
            nil
          end
        end

        def resolve_resource_path
          res = source_resource
          return nil unless res

          Decidim::ResourceLocatorPresenter.new(res).path
        rescue StandardError
          nil
        end

        def resolve_resource_url
          res = source_resource
          return nil unless res

          Decidim::ResourceLocatorPresenter.new(res).url
        rescue StandardError
          nil
        end
      end
    end
  end
end

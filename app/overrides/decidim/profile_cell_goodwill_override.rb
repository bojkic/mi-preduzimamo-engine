# frozen_string_literal: true

# Replaces Decidim's social-profile details with the MI public recognition
# contract: real display name, optional public MI recognition, no social graph
# counts and no wallet/private account data.
module Decidim
  module Bih
    module Goodwill
      module ProfileCellGoodwillOverride
        private

        def details_items
          items = [
            { icon: "account-pin-circle-line", text: nickname }
          ]
          items.append(icon: "link", text: personal_url, url: personal_url) if personal_url.present?

          append_recognition_hidden_notice(items) if public_profile.own_profile? && !public_profile.public_recognition_enabled?
          return items unless public_profile.recognition_visible?

          append_verification_badges(items)
          append_public_activity_badges(items)
          append_komsiluk_badge(items)
          items
        end

        def user_tabs
          [:contribution, :activity, :badges].map { |key| tab_item(key) }
        end

        def tab_item(key)
          values = {
            contribution: {
              icon: "vip-crown-line",
              path: profile_path(nickname: profile_holder.nickname),
              text: I18n.t("decidim.bih.public_profile.tabs.contribution")
            },
            activity: {
              icon: "bubble-chart-line",
              path: profile_activity_path(nickname: profile_holder.nickname),
              text: I18n.t("decidim.bih.public_profile.tabs.activity")
            },
            badges: {
              icon: "award-line",
              path: profile_badges_path(nickname: profile_holder.nickname),
              text: I18n.t("decidim.bih.public_profile.tabs.badges")
            }
          }

          values.fetch(key)
        end

        def profile_child_context
          raw_context = context.respond_to?(:to_h) ? context.to_h : {}
          raw_context.except(:content_cell, :active_content)
        rescue StandardError
          {}
        end

        def profile_tab_active?(path)
          controller.request.path == path.to_s.split("?").first
        end

        def append_recognition_hidden_notice(items)
          items.append(
            icon: "shield-check-line",
            text: I18n.t("decidim.bih.goodwill.profile.recognition_hidden"),
            url: public_profile.account_url
          )
        end

        def append_verification_badges(items)
          # Verified-citizen flair is independent of whether the holder has points.
          items.append(icon: "checkbox-circle-line", text: I18n.t("decidim.bih.goodwill.profile.verified")) if public_profile.verified?
          items.append(icon: "mail-send-line", text: I18n.t("decidim.bih.goodwill.profile.postal_verified")) if public_profile.postal_verified?
        end

        def append_public_activity_badges(items)
          items.append(icon: "map-pin-line", text: I18n.t("decidim.bih.goodwill.profile.reporter")) if public_profile.reporter?
          items.append(icon: "hand-heart-line", text: I18n.t("decidim.bih.goodwill.profile.volunteer")) if public_profile.volunteer?
        end

        def append_komsiluk_badge(items)
          return if public_profile.komsiluk_name.blank?

          items.append(
            icon: "home-heart-line",
            text: I18n.t("decidim.bih.public_profile.badges.komsiluk.text", name: public_profile.komsiluk_name)
          )
        end

        def public_profile
          @public_profile ||= Decidim::Bih::PublicProfilePresenter.new(user: profile_holder, viewer: current_user)
        end
      end
    end
  end
end

Decidim::ProfileCell.prepend(Decidim::Bih::Goodwill::ProfileCellGoodwillOverride)

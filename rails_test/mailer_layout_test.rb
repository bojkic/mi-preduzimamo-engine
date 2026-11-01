# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The engine replaces Decidim's transactional mail layout
      # (app/views/layouts/decidim/mailer.html.erb). These tests pin what the
      # replacement promises: no dark bands, no webpack stylesheet for
      # premailer to fetch, the organisation's own accent colour, and every
      # Decidim mailer that declares the layout — notifications and Devise —
      # rendering through it.
      class MailerLayoutTest < ActiveSupport::TestCase
        CORE_DARK_BAND = "#1a181d"

        setup do
          @organization = create_organization(
            colors: { "primary" => "#d86b4a", "tertiary" => "#1c3d53" }
          )
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization, locale: "sr")
        end

        test "welcome notification renders in Serbian through the engine layout" do
          mail = welcome_mail
          html = html_of(mail)

          assert_equal I18n.t("decidim.welcome_notification.default_subject", locale: :sr)
                           .gsub("{{organization}}", @organization.name["sr"] || @organization.name.values.first),
                       mail.subject
          assert_includes html, "Zdravo"
          assert_includes html, "Pomoć"
        end

        test "layout paints no dark bands and links no webpack pack" do
          html = html_of(welcome_mail)

          refute_includes html, CORE_DARK_BAND
          refute_includes html, "decidim-bar"
          refute_includes html, "cityhall-bar"
          refute_includes html, "/packs"
          refute_includes html, "decidim_email"
          refute_includes html, "<link"
        end

        test "layout uses the organisation's accent colour and links home" do
          html = html_of(welcome_mail)

          assert_includes html, "#d86b4a"
          assert_includes html, "#1c3d53"
          assert_includes html, "//#{@organization.host}/"
          assert_includes html, I18n.t("decidim.newsletter_mailer.newsletter.no_reply_notice", locale: :sr)
        end

        test "an organisation without a palette still renders" do
          @organization.update!(colors: {})
          html = html_of(welcome_mail)

          assert_includes html, "#2f5570"
          refute_includes html, CORE_DARK_BAND
        end

        test "devise mail renders through the same layout" do
          mail = Decidim::DecidimDeviseMailer.reset_password_instructions(@citizen, "harness-token").deliver_now
          html = html_of(mail)

          refute_includes html, CORE_DARK_BAND
          refute_includes html, "/packs"
          assert_includes html, "#d86b4a"
        end

        private

        def welcome_mail
          Decidim::NotificationMailer.event_received(
            "decidim.events.core.welcome_notification",
            "Decidim::WelcomeNotificationEvent",
            @citizen,
            @citizen,
            "affected_user",
            { force_email: true }
          ).deliver_now
        end

        def html_of(mail)
          part = mail.html_part || mail
          part.body.decoded
        end
      end
    end
  end
end

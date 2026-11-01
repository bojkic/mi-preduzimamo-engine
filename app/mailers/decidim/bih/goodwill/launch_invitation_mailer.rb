# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # E-mail sa ulaznim kodom za lansiranje 17.9.
      #
      # Prati obrazac koji engine vec koristi (OperatorRoleExpiryMailer):
      # ActionMailer::Base sa eksplicitnim `from:` i tekstualnim tijelom, bez
      # ERB predloska. Razlog: to je jedini oblik dokazan u ovom engine-u.
      class LaunchInvitationMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer
        include Decidim::Bih::SenderAddress

        def invitation(fulfillment, confirm_url: nil)
          user = fulfillment.user
          organization = fulfillment.organization
          locale = organization.default_locale.presence || "sr"

          subject, body = I18n.with_locale(locale) do
            scope = "decidim.bih.goodwill.launch_invitation_mailer.invitation"
            [
              I18n.t("#{scope}.subject"),
              [
                I18n.t("#{scope}.greeting", name: user.name.presence || user.nickname),
                I18n.t("#{scope}.body"),
                fulfillment.entry_code,
                I18n.t("#{scope}.entry_note"),
                (I18n.t("#{scope}.confirm_link", url: confirm_url) if confirm_url.present?),
                I18n.t("#{scope}.confirm_prompt",
                       deadline: I18n.l(fulfillment.confirmation_deadline_at, format: :long)),
                I18n.t("#{scope}.confirm_where", url: rewards_url(organization)),
                I18n.t("#{scope}.no_points_note")
              ].compact.join("\n\n")
            ]
          end

          mail(
            to: user.email,
            from: sender_address,
            subject:,
            body: "#{body}\n"
          )
        end

        private

        # Rewards tab of the community hub, sign-in required, NO code/token in
        # the query string. Built via Decidim::Bih.public_url so the engine's
        # own citizen-facing mount path stays host-configurable — never
        # hardcode "/biceriseno" (or any other host's mount prefix) here.
        def rewards_url(organization)
          Decidim::Bih.public_url(
            "zajednistvo?tab=nagrade",
            base_url: "https://#{organization.host}"
          )
        end
      end
    end
  end
end

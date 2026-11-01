# frozen_string_literal: true

module Decidim
  module Bih
    # The "prove your e-mail address" message. Its only payload is a link back
    # to EmailConfirmationsController#show; following it proves the address and
    # nothing else — no phone verification, no points.
    #
    # Deliberately a mailer of its own rather than another action on the
    # registration mailer: the two have different lifetimes (one is part of
    # sign-up, this one is available forever from Moj nalog) and different log
    # discipline (this one's argument is a bearer token).
    #
    # Plain text built in Ruby, ActionMailer::Base, explicit `from:` — the same
    # shape as Goodwill::LaunchInvitationMailer and OperatorRoleExpiryMailer.
    # ActionMailer::Base keeps Decidim's "decidim/mailer" layout out of the
    # way (the layout is now the engine's own pack-free one, so this is a
    # choice, not a constraint); the Ruby-built body is a preference, not a
    # requirement — RegistrationMailer renders ERB on the same base class.
    #
    # The sender is REPORTER_MAILER_FROM / Decidim::Bih.reporter_mailer_from,
    # which is what the majority of this engine's citizen-facing mailers
    # already use (RegistrationMailer, ReporterMailer, Launch::InvitationMailer)
    # — one knob for the address a citizen sees, not two.
    class EmailConfirmationMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer
      SCOPE = "decidim.bih.email_confirmation_mailer.confirm"
      DEFAULT_FROM = "notifications@example.org"

      # Keeps the token out of the ActiveJob enqueue/perform log lines; see
      # EmailConfirmationDeliveryJob.
      self.delivery_job = Decidim::Bih::EmailConfirmationDeliveryJob

      def confirm(user, token)
        return if user.email.blank?

        organization = user.organization
        locale = user.locale.presence || organization.default_locale.presence || "sr"

        subject, body = I18n.with_locale(locale) do
          [
            I18n.t("#{SCOPE}.subject"),
            [
              I18n.t("#{SCOPE}.greeting", name: user.name.presence || user.nickname),
              I18n.t("#{SCOPE}.body"),
              confirmation_url(token, organization),
              I18n.t("#{SCOPE}.note"),
              I18n.t("#{SCOPE}.ignore")
            ].join("\n\n")
          ]
        end

        mail(to: user.email, from: sender_address, subject:, body: "#{body}\n")
      end

      private

      def sender_address
        ENV.fetch("REPORTER_MAILER_FROM", nil).presence ||
          Decidim::Bih.reporter_mailer_from.presence ||
          DEFAULT_FROM
      end

      # Built through Decidim::Bih.public_url so the engine's citizen-facing
      # mount path stays host-configurable — never hardcode "/biceriseno".
      def confirmation_url(token, organization)
        Decidim::Bih.public_url(
          "potvrdi-email/#{token}",
          base_url: "https://#{organization.host}"
        )
      end
    end
  end
end

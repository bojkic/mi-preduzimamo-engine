# frozen_string_literal: true

module Decidim
  module Bih
    # The registration reminders: #resume at 15 minutes
    # (ResumeRegistrationEmailJob) and #final_notice on day 5
    # (Registration::PendingLifecycle).
    #
    # ActionMailer::Base rather than Decidim::ApplicationMailer, like every
    # other mailer in this engine. The original reason — Decidim's mailer
    # layout linked a webpack stylesheet a generated host cannot serve — is
    # gone since this engine replaced that layout with a pack-free one
    # (app/views/layouts/decidim/mailer.html.erb); the plain shape is kept
    # because nothing in this message needs a layout: a greeting, one
    # sentence and one link.
    #
    # Deliver it with deliver_now (the job does). deliver_later would put the
    # pending token into ActionMailer::MailDeliveryJob's logged arguments.
    #
    # PRIVACY: the message carries the citizen's own name and their own pending
    # token, nothing else. No phone number, no verification code, no points, no
    # komšiluk.
    class RegistrationMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer
      DEFAULT_FROM = "notifications@example.org"

      # Registry keys for the two messages this mailer sends. Stamping the
      # correlation header is what ENROLLS a mailer in the shared history: a
      # mailer without one keeps its own evidence and is listed as uncovered,
      # rather than being half-recorded.
      RESUME_CLASS = "registration.resume_email"
      FINAL_NOTICE_CLASS = "registration.final_notice_email"

      def resume(user, token)
        @user = user
        @organization = user.organization
        @url = resume_url(token)

        stamp_intent(RESUME_CLASS, user, "registration_resume:#{user.id}")
        I18n.with_locale(user.locale.presence || @organization.default_locale) do
          mail(
            to: user.email,
            from: sender_address,
            subject: I18n.t("decidim.bih.registration_mailer.resume.subject")
          )
        end
      end

      # Day 5 of Registration::PendingLifecycle: the account will be removed
      # in 48 hours. Same shape and the same privacy rule as #resume.
      def final_notice(user, token)
        @user = user
        @organization = user.organization
        @url = resume_url(token)
        stamp_intent(FINAL_NOTICE_CLASS, user, "registration_final_notice:#{user.id}")
        I18n.with_locale(user.locale.presence || @organization.default_locale) do
          mail(
            to: user.email,
            from: sender_address,
            subject: I18n.t("decidim.bih.registration_mailer.final_notice.subject")
          )
        end
      end

      private

      # The correlation key is the citizen's own id and the message's purpose —
      # never the pending token. A token in a correlation key would put a live
      # credential into a ledger row, an index and every operator screen that
      # reads one. The header itself is stripped before the message is handed to
      # SMTP (Messaging::MailRecorder), so the reference never leaves the
      # building either.
      def stamp_intent(message_class, user, correlation_key)
        headers[Decidim::Bih::Messaging::MailRecorder::HEADER] =
          Decidim::Bih::Messaging::MailRecorder.reference(
            message_class:, organization_id: @organization&.id,
            correlation_key:, recipient_kind: "account", account_id: user.id
          )
      rescue StandardError => e
        # A correlation header must never be able to stop a registration mail.
        Rails.logger.warn("[messaging] registration mail stamp: #{e.class}")
      end

      # The pending page, wherever this host serves it. Decidim::Bih.registration_url
      # owns that rule (registration_base_path, falling back to the engine
      # mount) so the mailed link and the pages themselves can never disagree
      # about where the flow lives. There is no request here to derive a scheme
      # or a host from, hence the same "https://#{host}" shape as
      # Decidim::Bih.magic_link_url.
      def resume_url(token)
        Decidim::Bih.registration_url(
          "potvrda?pending_token=#{CGI.escape(token.to_s)}",
          host: @organization.host
        )
      end

      def sender_address
        ENV.fetch("REPORTER_MAILER_FROM", nil).presence ||
          Decidim::Bih.reporter_mailer_from.presence ||
          DEFAULT_FROM
      end
    end
  end
end

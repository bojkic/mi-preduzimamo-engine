# frozen_string_literal: true

module Decidim
  module Bih
    # Sends plain-text status-update emails to the citizen who filed a report,
    # when their report's status changes. Mirrors Sistem48::ReportMailer style:
    # composed inline (no view template), plain text only, i18n'd in all four
    # locales via the engine's locale files.
    #
    # PRIVACY: this mailer sends ONLY the citizen's own data back to the address
    # they supplied. It never includes reporter_phone or any PII beyond the
    # reference and public status. The status_note (rejection reason) is included
    # ONLY when the new status is `odbijeno` — it is the rejection reason the
    # citizen deserves and the admin labeled it as such. For all other statuses
    # the note is an internal operator annotation and is NOT sent.
    # The status page URL uses the report's unguessable token. The public
    # reference route remains PII-light, but reporter notifications should use
    # the tokenized path before any private details expand.
    #
    # Delivery is enqueued by the Report after_update_commit callback so it runs
    # outside the request cycle. All errors are rescued and logged via
    # LogRedactor — this mailer must never crash the callback chain.
    class ReporterMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer
      DEFAULT_FROM = "notifications@example.org"
      MESSAGE_CLASS = "report.reporter_status_email"

      # report    — a Decidim::Bih::Report instance
      # locale    — the preferred i18n locale for this organization (string)
      # host      — organization host for building the status URL
      def status_update(report, locale: "sr", host: nil)
        return unless Messaging::ProactiveEmail.report_allowed?(report)

        @report = report
        @reference = report.reference
        @status = report.status
        # Include the rejection reason only for the `odbijeno` status — this is
        # the only note that is citizen-facing (admin field label makes this explicit).
        @status_note = report.status == "odbijeno" && !report.duplicate? ? report.status_note.presence : nil
        @status_url = build_status_url(report, host: host || report.organization&.host)
        @locale = locale.to_s

        stamp_intent(report)
        mail(
          **ReportMailbox::Transport.options!,
          reply_to: citizen_reply_address(report),
          to: report.reporter_email,
          from: Decidim::Bih.report_mail_transport == "gmail" ? Decidim::Bih.report_reply_mailbox : sender_address,
          subject: subject_for(report),
          body: body_for
        )
      end

      # Questions use a capability bound to the exact question identity.
      def case_message(message)
        report = message.report
        return unless report.author&.confirmed?
        address = citizen_reply_address(report, question_message: message.kind == "question" ? message : nil)
        mail(**ReportMailbox::Transport.options!, to: report.author.email,
             from: Decidim::Bih.report_mail_transport == "gmail" ? Decidim::Bih.report_reply_mailbox : sender_address,
             reply_to: address, subject: report.reference, body: message.external_notification_text)
      end

      private

      def citizen_reply_address(report, question_message: nil)
        return nil unless report.author&.confirmed?
        correspondents = [report.author.email]
        ReportMailbox::ReplyAddress.ensure!(report:, audience: "citizen", correspondents:, question_message:)
        ReportMailbox::ReplyAddress.address_for(report:, audience: "citizen", correspondents:, question_message:)
      end

      # This address is the report's OWN contact address. It is not an account,
      # and it must never be resolved into one: two different people can give
      # the same address, and a report contact who also happens to hold an
      # account did not thereby consent to their account's preferences
      # governing this mail. So the recipient kind is
      # `anonymous_report_contact`, the intent stores a scoped safe reference
      # derived from that address, and no account id is carried at all.
      def stamp_intent(report)
        headers[Decidim::Bih::Messaging::MailRecorder::HEADER] =
          Decidim::Bih::Messaging::MailRecorder.reference(
            message_class: MESSAGE_CLASS, organization_id: report.decidim_organization_id,
            correlation_key: "report:#{report.id}:status:#{report.status}",
            recipient_kind: "anonymous_report_contact"
          )
      rescue StandardError => e
        Rails.logger.warn("[messaging] reporter mail stamp: #{e.class}")
      end

      def sender_address
        ENV.fetch("REPORTER_MAILER_FROM", nil).presence ||
          Decidim::Bih.reporter_mailer_from.presence ||
          DEFAULT_FROM
      end

      def subject_for(report)
        I18n.with_locale(@locale) do
          I18n.t(
            "decidim.bih.reporter_mailer.status_update.subject",
            reference: report.reference,
            status: Decidim::Bih::ReportStatusPresenter.label(report)
          )
        end
      end

      def body_for
        I18n.with_locale(@locale) do
          lines = [
            I18n.t("decidim.bih.reporter_mailer.status_update.greeting"),
            "",
            I18n.t(
              "decidim.bih.reporter_mailer.status_update.body",
              reference: @reference,
              status: Decidim::Bih::ReportStatusPresenter.label(@report)
            )
          ]

          lines << ReportStatusPresenter.duplicate_message(@report) if @report.duplicate?

          if @status == "planirano" && !@report.duplicate?
            lines << ""
            lines << I18n.t("decidim.bih.report_planning.citizen_notification")
          end

          if @status_note.present?
            lines << ""
            lines << I18n.t(
              "decidim.bih.reporter_mailer.status_update.note",
              note: @status_note
            )
          end

          lines << ""
          lines << I18n.t(
            "decidim.bih.reporter_mailer.status_update.status_link",
            url: @status_url
          )
          lines << ""
          lines << I18n.t("decidim.bih.reporter_mailer.status_update.footer")

          "#{lines.join("\n")}\n"
        end
      end

      def build_status_url(report, host:)
        path = report.tokenized_status_path
        return path if host.blank?

        "https://#{host}#{path}"
      end
    end
  end
end

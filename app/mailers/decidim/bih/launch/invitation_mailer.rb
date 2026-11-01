# frozen_string_literal: true

module Decidim
  module Bih
    module Launch
      # Delivers one already-rendered launch campaign message (see
      # MessageTemplates) to a citizen by email. Plain text only — no HTML
      # template — mirroring ReporterMailer/AnalyticsDigestMailer style.
      #
      # params:
      #   user:        — the Decidim::User recipient (mail goes to user.email)
      #   body:        — the already-rendered message text (see
      #                  MessageDispatcher — this may be the :email or the
      #                  :viber variant of the template, depending on which
      #                  channel MessageDispatcher chose to reuse)
      #   message_key: — the P-message key ("p1".."p11"), used only to look up
      #                  a dedicated subject line when one exists
      #   locale:      — the locale the body/subject were rendered in
      class InvitationMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer
        include Decidim::Bih::SenderAddress

        # The default delivery job (ActionMailer::MailDeliveryJob) logs its
        # arguments — including the rendered body, which for P1 carries the
        # citizen's venue entry code and a bearer-token confirmation link.
        # See InvitationDeliveryJob for the full rationale (spec §10).
        self.delivery_job = InvitationDeliveryJob

        def campaign_message
          user = params.fetch(:user).reload
          return unless Messaging::ProactiveEmail.allowed?(user, topic: :platform_news)

          body = params.fetch(:body)
          message_key = params.fetch(:message_key)
          locale = params[:locale].presence || "sr"

          mail(to: user.email, from: sender_address, subject: subject_for(message_key, locale), body: "#{body}\n")
        end

        private

        def subject_for(message_key, locale)
          I18n.with_locale(locale) do
            I18n.t(
              "decidim.bih.launch.messages.#{message_key}.email_subject",
              default: I18n.t("decidim.bih.launch.messages.default_email_subject")
            )
          end
        end
      end
    end
  end
end

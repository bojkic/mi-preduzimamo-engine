# frozen_string_literal: true

module Decidim
  module Bih
    # Supplies the configured monitored mailbox without replacing an explicit
    # message reply address. Decidim0.32 removed the old mailer_reply setting;
    # core's organization SMTP fallback would otherwise use the From address.
    # The delivery interceptor still covers non-core mailers and nil defaults
    # keep another community's mail out of an unconfigured inbox.
    module MailReplyTo
      module CoreSmtpDefaults
        private

        def set_smtp
          Decidim::Bih::MailReplyTo.delivering_email(mail)
          super
        end
      end

      module_function

      def delivering_email(message)
        return if message.reply_to.present?

        address = Decidim::Bih.mailer_reply_to.presence
        return if address.blank?

        message.reply_to = address
      rescue StandardError => e
        # A hook that raises breaks the mail it is riding on.
        Rails.logger.warn("[messaging] reply-to interceptor: #{e.class}")
      end
    end
  end
end

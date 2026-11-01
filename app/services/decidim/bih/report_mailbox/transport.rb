# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      module Transport
        class Unavailable < StandardError; end
        def self.settings!
          return nil if Decidim::Bih.report_mail_transport == "relay"
          raise Unavailable, "Unknown report mail transport" unless Decidim::Bih.report_mail_transport == "gmail"
          config = Config.load or raise Unavailable, "Mailbox configuration unavailable"
          raise Unavailable, "Mailbox sender mismatch" unless config.username.casecmp?(Decidim::Bih.report_reply_mailbox.to_s)
          config.smtp_settings
        rescue Config::Invalid, Config::InsecureFile, SystemCallError
          raise Unavailable, "Mailbox configuration unavailable"
        end
        def self.options!
          settings = settings!
          settings ? { delivery_method: :smtp, delivery_method_options: settings, from: Decidim::Bih.report_reply_mailbox } : {}
        end
      end
    end
  end
end

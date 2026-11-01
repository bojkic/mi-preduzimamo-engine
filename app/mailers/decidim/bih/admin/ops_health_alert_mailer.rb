# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # PII-free alert containing only structured health metric identifiers.
      class OpsHealthAlertMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer
        include Decidim::Bih::SenderAddress

        def alert(organization:, recipient:, rows:)
          body = [
            "MI platform operational health requires review.",
            "Organization: #{organization.host}",
            "Generated: #{Time.current.utc.iso8601}",
            "",
            *rows.map { |row| row.join("\t") },
            "",
            "Run script/mi_ops_health_smoke and script/mi_cron_health_smoke on the server for bounded details."
          ].join("\n")

          mail(
            to: recipient,
            from: sender_address,
            subject: I18n.t("decidim.bih.admin.ops_health_alert_mailer.subject"),
            body:
          )
        end
      end
    end
  end
end

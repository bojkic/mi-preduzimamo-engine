# frozen_string_literal: true

module Decidim
  module Bih
    class OperatorRoleExpiryMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer
      include Decidim::Bih::SenderAddress

      def warning(operator_role, warning_days:)
        user = operator_role.user
        locale = operator_role.organization.default_locale.presence || "sr"
        subject, body = I18n.with_locale(locale) do
          role_label = I18n.t("decidim.bih.admin.operator_roles.roles.#{operator_role.role}", default: operator_role.role.humanize)
          expires_on = I18n.l(operator_role.expires_at.to_date)
          [
            I18n.t("decidim.bih.operator_role_expiry.email_subject", role: role_label, default: "Operatorska uloga uskoro ističe: %{role}"),
            I18n.t(
              "decidim.bih.operator_role_expiry.email_body",
              name: user.name.presence || user.nickname,
              role: role_label,
              date: expires_on,
              days: warning_days,
              default: "%{name}, tvoja operatorska uloga %{role} ističe %{date}. Obnova nije automatska. " \
                       "Obrati se administratoru koji mora potvrditi potrebu i upisati novo obrazloženje."
            )
          ]
        end
        mail(to: user.email, from: sender_address, subject:, body: "#{body}\n")
      end
    end
  end
end

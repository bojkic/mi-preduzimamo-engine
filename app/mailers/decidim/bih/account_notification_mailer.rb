# frozen_string_literal: true

module Decidim
  module Bih
    # The account intent already owns the encrypted body and delivery claim.
    # Delivery runs synchronously inside its worker; no body enters a mail job.
    class AccountNotificationMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer
      def notification(record)
        user = record.user
        topic = TopicPreferences.canonical_topic(record.topic)
        return unless Messaging::ProactiveEmail.allowed?(user, topic:)
        return unless user.decidim_organization_id == record.decidim_organization_id

        payload = record.payload
        I18n.with_locale(user.locale.presence || record.organization.default_locale) do
          mail(to: user.email, from: SenderAddress.call,
               subject: I18n.t("decidim.bih.communication_settings.topics.#{topic}"),
               content_type: "text/plain", body: payload.fetch("text"))
        end
      end
    end
  end
end

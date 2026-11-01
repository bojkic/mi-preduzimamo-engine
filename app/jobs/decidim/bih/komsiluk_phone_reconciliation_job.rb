# frozen_string_literal: true

module Decidim
  module Bih
    class KomsilukPhoneReconciliationJob < Decidim::ApplicationJob
      queue_as :integrations
      self.log_arguments = false

      def perform(id, poll = 0)
        delivery = KomsilukPhoneDelivery.find_by(id:)
        return unless delivery && %w(accepted unknown).include?(delivery.status)

        delivery.update!(provider_checked_at: Time.current)
        client = Infobip::Client.new
        delivery.provider_message_ids.each do |message_id|
          response = client.message_delivery_reports(message_id:)
          Array(response["results"]).each do |report|
            next unless report["messageId"].to_s == message_id.to_s

            status = report.fetch("status", {})
            delivery.with_lock do
              if status["name"] == "DELIVERED_TO_HANDSET"
                delivery.update!(status: "delivered", delivered_at: Time.current, provider_status: "DELIVERED_TO_HANDSET", reason: nil)
              elsif %w(REJECTED UNDELIVERABLE EXPIRED).include?(status["groupName"]) && delivery.status != "delivered"
                # A failing first leg is not a terminal failure of its managed
                # chain. Never make a new application request from this report.
                attributes = { provider_status: status["groupName"], reason: "provider_#{status["groupName"].downcase}" }
                attributes[:status] = "failed" if delivery.channels.one?
                delivery.update!(attributes)
              end
            end
          end
        end
        self.class.set(wait: 5.minutes).perform_later(id, poll + 1) if %w(accepted unknown).include?(delivery.reload.status) && poll < 12
      rescue StandardError => e
        Rails.logger.warn("[komsiluk_delivery] receipt unavailable #{e.class}")
        self.class.set(wait: 5.minutes).perform_later(id, poll + 1) if poll < 12
      end
    end
  end
end

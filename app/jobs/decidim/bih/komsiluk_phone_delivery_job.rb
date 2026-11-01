# frozen_string_literal: true

module Decidim
  module Bih
    class KomsilukPhoneDeliveryJob < Decidim::ApplicationJob
      queue_as :integrations
      self.log_arguments = false

      def perform(id)
        delivery = KomsilukPhoneDelivery.find_by(id:)
        return unless delivery
        return unless claim(delivery)

        post = delivery.platform_delivery.komsiluk_post
        return skip(delivery, "post_unavailable") unless post

        # Hold settings use this lock too. A hold cannot commit between the
        # current policy check and provider handoff. Source locks come next.
        delivery.organization.with_lock("FOR NO KEY UPDATE") { dispatch_guarded(delivery, post) }
      rescue Infobip::Error => e
        finish_failure(delivery, e.definitive_rejection? ? "rejected" : "unknown", e.class.name)
      rescue StandardError => e
        # A crash after the committed claim may be after provider acceptance.
        # Keep its reservation and reconcile; never retry a possibly sent SMS.
        finish_failure(delivery, "unknown", e.class.name)
      end

      private

      def dispatch_guarded(delivery, post)
        dispatch = -> { dispatch_locked(delivery, post) }
        if post.display_origin == "city_service" || post.details.to_h["source_record"].present?
          guard = Komsiluk::NoticePhonePolicy.source_dispatch_guard
          return skip(delivery, "source_review_required") unless guard

          yielded = false
          guard.call(post:, user: delivery.user) do
            yielded = true
            dispatch.call
          end
          skip(delivery, "source_changed") unless yielded
        else
          dispatch.call
        end
      end

      def claim(delivery)
        delivery.with_lock do
          next false unless delivery.status == "pending" && delivery.due_at <= Time.current

          if delivery.expires_at <= Time.current
            skip(delivery, "expired")
            next false
          end
          delivery.update!(status: "sending", attempted_at: Time.current)
          true
        end
      end

      def dispatch_locked(delivery, post)
        post.with_lock do
          receipt = delivery.platform_delivery
          receipt.with_lock do
            delivery.user.with_lock do
              profile = CitizenProfile.find_by(organization: delivery.organization, user: delivery.user)
              next skip(delivery, "membership_changed") unless profile

              profile.with_lock { dispatch_current(delivery, post, receipt) }
            end
          end
        end
      end

      def dispatch_current(delivery, post, receipt)
        payload = delivery.send_intent.phone_payload
        reason = current_blocker(delivery, post, receipt, payload)
        return skip(delivery, reason) if reason

        decision = Komsiluk::NoticePhonePolicy.eligible(user: delivery.user, organization: delivery.organization,
                                                        channels: delivery.channels, text: payload[:text], template: payload[:template], sms_text: payload[:sms_text])
        return skip(delivery, "destination_or_eligibility_changed") if decision[:destination_digest] != delivery.destination_digest || decision[:channels].empty?

        channels = decision[:channels]
        readiness = Komsiluk::NoticePhonePolicy.readiness(organization: delivery.organization, channels:,
                                                          mode: payload[:mode], text: payload[:text])
        return skip(delivery, readiness.first) if readiness.any?

        delivery.update!(channels:)
        response = Infobip::Client.new.send_phone_message(
          to: VerifiedPhone.delivery_phone_for(user: delivery.user, organization: delivery.organization),
          text: channels.include?("sms") ? payload.fetch(:sms_text) : payload.fetch(:text),
          viber_text: payload.fetch(:text), whatsapp_template: payload[:template],
          channels: channels.map(&:to_sym), final_sms: channels.include?("sms"), expires_at: delivery.expires_at,
          channel_validity_seconds: Infobip::Client::CAMPAIGN_CHANNEL_VALIDITY
        )
        ids = Array(response["messages"]).filter_map { |message| message["messageId"].presence }.uniq
        delivery.update!(status: ids.empty? ? "unknown" : "accepted", provider_message_ids: ids,
                         reason: ids.empty? ? "provider_identity_missing" : nil)
        KomsilukPhoneReconciliationJob.set(wait: 1.minute).perform_later(delivery.id) if ids.any?
      end

      def current_blocker(delivery, post, receipt, payload)
        return "intent_unavailable" unless delivery.send_intent.state == "confirmed"
        return "permission_revoked" unless OperatorAuthorization.allowed?(delivery.send_intent.actor, :broadcast_send_viber, organization: delivery.organization)
        if post.display_origin == "city_service" && !OperatorAuthorization.allowed?(delivery.send_intent.actor, :city_alerts_manage, organization: delivery.organization)
          return "permission_revoked"
        end
        return "phone_area_held" if Komsiluk::NoticePhonePolicy.area_held?(organization: delivery.organization, komsiluk_id: post.komsiluk_id)
        return "phone_area_policy_changed" unless payload[:phone_area_policy] == Komsiluk::PhoneAreaHolds.snapshot(delivery.organization)
        return "expired" if delivery.expires_at <= Time.current
        return "publication_changed" unless payload[:content_revision] == post.content_revision
        return "publication_or_membership_changed" unless Komsiluk::NoticePublishing.current_receipt?(receipt)
        return "platform_acknowledged" if receipt.acknowledged_at && payload[:mode] != "urgent_sms_now"
        return "source_changed" if Komsiluk::NoticePhonePolicy.source_reason(post, user: delivery.user)
        return "legacy_delivery_exists" if receipt.account_notification_id
        return "template_changed" if delivery.channels.include?("whatsapp") && payload[:template] != Komsiluk::NoticePhonePolicy.template(payload[:text])
        return "sms_policy_required" if delivery.channels.include?("sms") && !Komsiluk::NoticePhonePolicy.sms_config(delivery.organization)[:enabled]

        nil
      end

      def skip(delivery, reason)
        delivery.with_lock do
          next unless %w(pending sending).include?(delivery.status)

          delivery.update!(status: "skipped", reason: reason.to_s.first(80))
          Komsiluk::NoticePhonePolicy.release_budget!(delivery)
        end
      end

      def finish_failure(delivery, status, reason)
        return unless delivery&.persisted?

        finished = delivery.with_lock do
          next false unless delivery.status == "sending"

          delivery.update!(status:, reason: reason.to_s.first(80))
          Komsiluk::NoticePhonePolicy.release_budget!(delivery) if status == "rejected"
          true
        end
        Rails.logger.warn("[komsiluk_delivery] outcome=#{status} error=#{reason}") if finished
      end
    end
  end
end

# frozen_string_literal: true

require "web-push"

module Decidim
  module Bih
    class WebPushDeliveryJob < Decidim::ApplicationJob
      include Decidim::PushSubscriptionEndpointValidator

      class TemporaryFailure < StandardError; end

      queue_as :events
      retry_on TemporaryFailure, wait: :polynomially_longer, attempts: 5 do |_job, _error|
        Rails.logger.warn("[web_push] outcome=retry_exhausted")
      end

      # How a per-device push outcome reads in the shared ledger. `accepted` is
      # the strongest honest word for a push service returning 201: it took the
      # request. Browser display acknowledgments are recorded independently on
      # PlatformDelivery; no provider outcome here may write `delivered`.
      LEDGER_OUTCOMES = {
        "accepted" => [Messaging::Outcome::ACCEPTED, "push_service_accepted"],
        "expired" => [Messaging::Outcome::EXPIRED, "subscription_expired"],
        "rejected" => [Messaging::Outcome::REJECTED, "push_service_rejected"],
        "skipped" => [Messaging::Outcome::SKIPPED, "eligibility_changed"],
        "uncertain" => [Messaging::Outcome::UNCERTAIN, "temporary_push_failure"],
        "retry_scheduled" => [Messaging::Outcome::UNCERTAIN, "temporary_push_failure"]
      }.freeze

      # `intent_id` is defaulted: jobs enqueued by the previous release carry
      # three arguments and must still run, uncorrelated, rather than raising.
      # Optional positional arguments preserve already-queued job serialization.
      def perform(user_id, fingerprint, destination = "notifications", intent_id = nil, topic = nil, notification_id = nil, platform_delivery_id = nil) # rubocop:disable Metrics/ParameterLists
        return unless WebPush.enabled?

        @platform_delivery_id = platform_delivery_id
        @intent_id = intent_id
        @leg_ref = fingerprint
        user = Decidim::User.where(blocked: false, deleted_at: nil).where.not(confirmed_at: nil).find_by(id: user_id)
        return unless user

        return unless claim_delivery(user)

        subscription = nil
        dispatch = lambda do
          user.with_lock do
            subscription = eligible_subscription(user, fingerprint, topic, notification_id)
            unless subscription
              record("skipped")
              next
            end
            deliver(user, subscription, destination)
          end
        end
        guarded_dispatch(user, &dispatch)
      rescue ::WebPush::InvalidSubscription, ::WebPush::ExpiredSubscription
        # Order is load-bearing and is never the other way round: if the removal
        # succeeded and the recording failed, the reason this device went away
        # would be gone for good.
        record("expired")
        remove_subscription(user, subscription)
      rescue ::WebPush::TooManyRequests, ::WebPush::PushServiceError, Timeout::Error, SocketError, IOError, SystemCallError
        record(@intent_id ? "uncertain" : "retry_scheduled")
        # A correlated claim already records possible acceptance. Retrying that
        # HTTP request could duplicate the message; legacy jobs retain retries.
        raise TemporaryFailure, "Temporary push delivery failure", cause: nil unless @intent_id
      rescue ::WebPush::Error
        # Provider exception messages can contain response bodies and endpoints.
        record("rejected")
      end

      private

      def guarded_dispatch(user)
        return yield unless @platform_delivery_id

        receipt = PlatformDelivery.find_by(id: @platform_delivery_id, user:)
        return record("skipped") unless receipt

        if receipt.komsiluk_post_id
          post = receipt.komsiluk_post
          return record("skipped") unless post

          guarded = lambda do
            accepted = Komsiluk::NoticePublishing.with_current_receipt(receipt) { yield }
            record("skipped") unless accepted
          end
          # Host source guards take event/incident locks before the post lock.
          return WebPush.delivery_guard ? WebPush.delivery_guard.call(receipt:, &guarded) : guarded.call
        end
        return record("skipped") unless WebPush.delivery_guard

        WebPush.delivery_guard.call(receipt:) { yield }
      end

      def eligible_subscription(user, fingerprint, topic, notification_id)
        return unless active_recipient?(user)
        return unless WebPush.topic_permitted?(user, topic)
        return unless notification_permitted?(user, notification_id)

        subscription = user.notifications_subscriptions.values.find { |item| WebPush.fingerprint(item) == fingerprint }
        subscription if WebPush.valid_subscription?(subscription)
      end

      def active_recipient?(user)
        !user.blocked? && !user.deleted? && user.confirmed_at.present?
      end

      def notification_permitted?(user, notification_id)
        return true unless notification_id

        notification = Decidim::Notification.find_by(id: notification_id, user:)
        return false unless notification
        return false if notification.deleted_resource? || notification.hidden_resource?

        TopicPreferences.enabled?(user, topic: Messaging::NotificationTopic.for(notification))
      end

      # Claim commits before HTTP. Replayed jobs for the same event/device
      # cannot send again after acceptance or an uncertain/crashed attempt.
      def claim_delivery(user)
        return true unless @intent_id

        intent = Messaging::Intent.find_by(id: @intent_id, user:, organization: user.organization)
        return false unless intent
        return false if intent.expires_at && intent.expires_at <= Time.current

        intent.with_lock do
          next false if intent.attempts.exists?(channel_group: "push", channel: "push", destination_version: @leg_ref)

          Messaging::Correlation.claim!(intent:, group: "push", channel: "push", leg_ref: @leg_ref,
                                        destination: { kind: :push_endpoint, value: @leg_ref })
          true
        end
      end

      def deliver(user, subscription, destination)
        ::WebPush.payload_send(
          message: JSON.generate(payload(user, destination)),
          endpoint: subscription.fetch("endpoint"),
          p256dh: subscription.fetch("p256dh"), auth: subscription.fetch("auth"),
          vapid: { public_key: Decidim.vapid_public_key, private_key: Decidim.vapid_private_key, subject: WebPush.subject },
          ttl: 3600, open_timeout: 5, read_timeout: 10
        )
        record("accepted")
      end

      def payload(user, destination)
        # Generic text also covers operator broadcasts and private conversations.
        # An inbox destination works even when a custom event has no resource URL.
        path = destination == "conversations" ? "/conversations" : "/notifications"
        receipt = PlatformDelivery.find_by(id: @platform_delivery_id, user:)
        receipt_url = receipt && Decidim::Bih::Engine.routes.url_helpers.platform_receipt_path(script_name: Decidim::Bih.normalized_public_mount_path)
        post = receipt&.komsiluk_post
        url = post ? Komsiluk::NoticePublishing.board_url(post) : "https://#{user.organization.host}#{path}"
        default_tag = destination == "conversations" ? "platform-messages" : "platform-notifications"
        tag = post ? "board-#{Digest::SHA256.hexdigest(receipt.identity).first(24)}" : default_tag
        I18n.with_locale(user.locale.presence || user.organization.default_locale) do
          {
            title: I18n.t("decidim.bih.web_push.title"),
            body: I18n.t("decidim.bih.web_push.body"),
            data: { url:, receipt_url:, receipt_token: receipt&.receipt_token },
            tag:
          }
        end
      end

      def remove_subscription(user, subscription)
        return unless user && subscription

        user.with_lock do
          settings = user.notification_settings.deep_dup
          settings["subscriptions"] = (settings["subscriptions"] || {}).reject do |_key, item|
            item == subscription
          end
          user.update!(notification_settings: settings)
        end
      end

      def record(outcome)
        Rails.logger.info("[web_push] outcome=#{outcome}")
        record_attempt(outcome)
      end

      # One attempt row per endpoint, keyed by the device fingerprint that
      # already exists for exactly this purpose — never the endpoint URL, which
      # is a bearer secret. A failed endpoint changes nothing about the others:
      # each device is its own job and its own row.
      def record_attempt(outcome)
        intent = @intent_id && Messaging::Intent.find_by(id: @intent_id)
        return if intent.nil?

        mapped, reason = LEDGER_OUTCOMES.fetch(outcome)
        Messaging::Correlation.record!(
          intent:, group: "push", channel: "push", outcome: mapped, reason:,
          leg_ref: @leg_ref, destination: { kind: :push_endpoint, value: @leg_ref }
        )
      rescue StandardError => e
        Rails.logger.warn("[web_push] ledger #{e.class}")
      end
    end
  end
end

# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    # Web Push is opt-in per browser. No notification bodies or subscription
    # secrets travel through the job queue or the delivery log.
    module WebPush
      class << self
        attr_accessor :delivery_guard
      end

      def self.enabled?
        ActiveModel::Type::Boolean.new.cast(ENV.fetch("DECIDIM_BIH_WEB_PUSH_ENABLED", "false")) &&
          Decidim.vapid_public_key.present? && Decidim.vapid_private_key.present? &&
          subject.match?(%r{\A(?:mailto:[^\s@]+@[^\s@]+|https://[^\s]+)\z})
      end

      def self.subject
        ENV.fetch("VAPID_SUBJECT", "")
      end

      def self.fingerprint(subscription)
        return unless subscription.is_a?(Hash) && subscription["auth"].is_a?(String) && subscription["auth"].present?

        Digest::SHA256.hexdigest(subscription.fetch("auth"))
      end

      MESSAGE_CLASS = "push.bell_fanout"

      # One logical message, one attempt PER DEVICE. The intent is created here,
      # where the fan-out decision is actually made, and its id travels with each
      # job so every device records its own independent outcome against one
      # intent — rather than each job inventing an intent of its own and turning
      # a three-device push into three logical messages.
      #
      # `intent_id` is a defaulted fourth argument on purpose: a job enqueued by
      # the previous release carries three, deserializes cleanly and simply does
      # not correlate. An undefaulted argument would raise ArgumentError on
      # every already-queued push at deploy time.
      # A setup capability, not delivery proof. Callers may use this only when
      # they also own a matching push-producing event for this topic.
      def self.available_for?(user, topic:)
        enabled? && user && TopicPreferences.enabled?(user, topic:) &&
          user.notifications_subscriptions.values.any? { |subscription| valid_subscription?(subscription) }
      end

      def self.valid_subscription?(subscription)
        fingerprint(subscription) && subscription["p256dh"].present? &&
          Object.new.extend(Decidim::PushSubscriptionEndpointValidator)
                .send(:supported_push_subscription_endpoint?, subscription["endpoint"])
      end

      # Old jobs carried no topic. They may proceed only if every topic remains
      # enabled: guessing could send a topic that the citizen switched off.
      def self.topic_permitted?(user, topic)
        topics = topic.nil? ? TopicPreferences::TOPICS : [topic]
        topics.all? { |candidate| TopicPreferences.enabled?(user, topic: candidate) }
      end

      def self.enqueue(user, destination: "notifications", topic: nil, notification_id: nil, deduplication_key: nil, platform_delivery: nil) # rubocop:disable Metrics/ParameterLists
        deduplication_key = platform_delivery.identity if platform_delivery
        topic = TopicPreferences.canonical_topic(topic) unless topic.nil?
        return false unless enabled? && user && topic_permitted?(user, topic)

        subscriptions = user.notifications_subscriptions.values.select { |subscription| valid_subscription?(subscription) }
        return false if subscriptions.empty?

        intent = delivery_intent(user, destination, notification_id:, deduplication_key:)

        enqueue_devices(user, subscriptions, destination, intent, topic, notification_id, platform_delivery)
        true
      end

      # Report-status producers need to know whether a push request made any
      # durable claim before choosing an alternate channel. `false` from
      # `enqueue` occurs before the intent; an exception can occur on either
      # side of intent creation, so it must be reconciled rather than replayed.
      # This separate API leaves the boolean/exception contract for existing
      # callers intact.
      def self.enqueue_with_claim_result(user, destination: "notifications", topic: nil, notification_id: nil) # rubocop:disable Metrics/ParameterLists
        begin
          topic = TopicPreferences.canonical_topic(topic) unless topic.nil?
          return :not_claimed unless enabled? && user && topic_permitted?(user, topic)

          subscriptions = user.notifications_subscriptions.values.select { |subscription| valid_subscription?(subscription) }
          return :not_claimed if subscriptions.empty?
        rescue StandardError => e
          Rails.logger.warn("[messaging] push preclaim check failed: #{e.class}")
          return :not_claimed
        end

        begin
          intent = delivery_intent(user, destination, notification_id:, deduplication_key: nil)
          queued = enqueue_devices(user, subscriptions, destination, intent, topic, notification_id, nil)
          queued ? :claimed_or_queued : :uncertain
        rescue StandardError => e
          Rails.logger.warn("[messaging] push claim state uncertain: #{e.class}")
          :uncertain
        end
      end

      def self.enqueue_devices(user, subscriptions, destination, intent, topic, notification_id, platform_delivery) # rubocop:disable Metrics/ParameterLists
        platform_delivery&.update!(push_queued_at: Time.current, push_intent_id: intent&.id)
        all_jobs_accepted = true
        subscriptions.each do |subscription|
          arguments = [user.id, fingerprint(subscription), destination, intent&.id, topic, notification_id]
          arguments << platform_delivery.id if platform_delivery
          all_jobs_accepted = false unless WebPushDeliveryJob.perform_later(*arguments)
        end
        all_jobs_accepted
      end

      def self.delivery_intent(user, destination, notification_id:, deduplication_key:)
        identity = deduplication_key || ("notification:#{notification_id}" if notification_id)
        intent = fanout_intent(user, destination, deduplication_key: identity)
        raise Messaging::DispatchEvidence::LedgerUnavailable, "push identity unavailable" if identity && intent.nil?

        intent
      end

      # Stable producer identities require durable evidence before enqueueing.
      # Old uncorrelated callers retain observational ledger compatibility.
      def self.fanout_intent(user, destination, deduplication_key: nil)
        Messaging::Correlation.intent_for(
          organization: user.organization, message_class: MESSAGE_CLASS,
          recipient: Messaging::RecipientContext.account(
            organization_id: user.decidim_organization_id, account_id: user.id, locale: user.locale
          ),
          correlation_key: "web_push:#{destination}:#{deduplication_key || SecureRandom.uuid}",
          deduplication_scope: "#{MESSAGE_CLASS}:#{destination}:#{user.id}",
          expires_at: Messaging::MessageClass.fetch(MESSAGE_CLASS).expires_in&.seconds&.from_now
        )
      rescue StandardError => e
        Rails.logger.warn("[messaging] push fanout intent: #{e.class}")
        nil
      end
    end
  end
end

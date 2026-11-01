# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Compatibility names for producer contracts. Optional deliveries share
      # canonical topic choices, while inbox, authentication, address, session
      # and role boundaries keep their own checks. Evaluation has no writes.
      module LegacyAdapters
        Result = Struct.new(:allowed, :reason, :origin, keyword_init: true) do
          def allowed?
            allowed == true
          end
        end

        # Adapters whose contract has no optional topic switch at all. A service
        # classification bypasses EXACTLY this — its own topic choice — and
        # nothing else: validity, tenant, address, suppression, expiry and rate
        # checks are applied by the policy regardless.
        TOPIC_EXEMPT = %w(requested_authentication core_transactional none one_time_test_permission).freeze

        TOPIC_ADAPTERS = {
          "report_updates_topic" => :report_updates,
          "community_news_topic" => :community_news,
          "city_service_alerts_topic" => :neighborhood_info,
          "neighborhood_info_topic" => :neighborhood_info,
          "platform_news_topic" => :platform_news
        }.freeze

        module_function

        def topic_exempt?(adapter)
          TOPIC_EXEMPT.include?(adapter.to_s)
        end

        def topic_for(adapter)
          TOPIC_ADAPTERS[adapter.to_s]
        end

        # rubocop:disable Metrics/CyclomaticComplexity
        def evaluate(adapter, user:, channel:, context:)
          case adapter.to_s
          when *TOPIC_EXEMPT then exempt(adapter)
          when *TOPIC_ADAPTERS.keys then stored_topic_key(adapter, user:, channel:)
          when "legacy_urgent_bell" then legacy_urgent_bell(user)
          when "core_notification_types" then core_notification_types(user, context)
          when "core_email_frequency" then core_email_frequency(user, context)
          when "core_newsletter" then core_newsletter(user)
          when "core_direct_message" then core_direct_message(user, context)
          when "core_moderation_email" then core_moderation_email(user)
          when "device_subscription" then device_subscription(context, user:)
          when "channel_session" then channel_session(context)
          when "report_contact_address" then report_contact_address(context)
          when "operator_recipient_config", "external_recipient_config" then configured_recipient(context)
          else Result.new(allowed: false, reason: :unknown_preference_adapter, origin: "unknown")
          end
        end
        # rubocop:enable Metrics/CyclomaticComplexity

        def exempt(adapter)
          Result.new(allowed: true, reason: nil, origin: adapter.to_s == "one_time_test_permission" ? "one_time_test" : "exempt")
        end

        # Historical method name; the channel no longer indexes a preference.
        def stored_topic_key(adapter, user:, channel:)
          MessageClass.topic_channel!(channel)
          topic = topic_for(adapter)
          return Result.new(allowed: false, reason: :account_unavailable, origin: "absent") if user.nil?

          allowed = channel.to_s == "email" ? ProactiveEmail.allowed?(user, topic:) : TopicPreferences.enabled?(user, topic:)
          Result.new(allowed:, reason: allowed ? nil : :preference_blocked, origin: "topic_preference")
        end

        # Historical producer adapter: inbox entries are always available.
        def legacy_urgent_bell(user)
          return Result.new(allowed: false, reason: :account_unavailable, origin: "absent") if user.nil?

          Result.new(allowed: true, reason: nil, origin: "platform_always_on")
        end

        # Resource access and recipient eligibility remain with core generation.
        def core_notification_types(user, _context)
          return Result.new(allowed: false, reason: :account_unavailable, origin: "absent") if user.nil?

          Result.new(allowed: true, reason: nil, origin: "platform_always_on")
        end

        def core_email_frequency(user, context)
          return Result.new(allowed: false, reason: :account_unavailable, origin: "absent") unless user

          event = context[:event_name] || context[:event] || ""
          topic = context[:topic] || NotificationTopic.for_event(event, extra: context)
          allowed = ProactiveEmail.allowed?(user, topic:) && context[:force_email] != false
          Result.new(allowed:, reason: allowed ? nil : :preference_blocked, origin: "topic_preference")
        end

        def core_newsletter(user)
          allowed = ProactiveEmail.allowed?(user, topic: :platform_news)
          Result.new(allowed:, reason: allowed ? nil : :preference_blocked, origin: "topic_preference")
        end

        def core_direct_message(user, context)
          return Result.new(allowed: false, reason: :account_unavailable, origin: "absent") if user.nil?

          sender = context[:sender]
          allowed = sender.nil? ? user.direct_message_types.to_s == "all" : user.accepts_conversation?(sender)
          Result.new(allowed:, reason: allowed ? nil : :direct_message_refused, origin: "account")
        end

        def core_moderation_email(user)
          return Result.new(allowed: false, reason: :account_unavailable, origin: "absent") if user.nil?

          allowed = user.email_on_moderations != false
          Result.new(allowed:, reason: allowed ? nil : :moderation_email_disabled, origin: "account")
        end

        # Browser permission is not a server preference and cannot be granted
        # here. No saved subscription means no device send, full stop.
        def device_subscription(context, user: nil)
          return Result.new(allowed: false, reason: :preference_blocked, origin: "topic_preference") if user && !WebPush.topic_permitted?(user, context[:notification_topic])

          count = context[:device_count].to_i
          Result.new(allowed: count.positive?, reason: count.positive? ? nil : :no_device_subscription,
                     origin: "device")
        end

        def channel_session(context)
          expires_at = context[:session_expires_at]
          return Result.new(allowed: false, reason: :session_expired, origin: "session") if expires_at.nil?

          allowed = expires_at > Time.current
          Result.new(allowed:, reason: allowed ? nil : :session_expired, origin: "session")
        end

        # The report's own contact address. There is no topic gate on this path
        # today: a status e-mail goes to the address the report carries.
        def report_contact_address(context)
          return Result.new(allowed: false, reason: :destination_unknown, origin: "absent") if context[:destination_present] != true
          return Result.new(allowed: false, reason: :initial_status_not_notified, origin: "report") if context[:initial_status] == true

          Result.new(allowed: true, reason: nil, origin: "report")
        end

        def configured_recipient(context)
          allowed = context[:configured_recipient] == true
          Result.new(allowed:, reason: allowed ? nil : :recipient_not_configured, origin: "configuration")
        end
      end
    end
  end
end

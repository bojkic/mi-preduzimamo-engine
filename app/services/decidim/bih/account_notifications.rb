# frozen_string_literal: true

require "digest"
require_relative "messaging/channel_selection"

module Decidim
  module Bih
    # Identity, permission and transport capability are checked independently.
    # A sending claim is committed BEFORE the network request. Crashes or lost
    # replies never restart the logical send; operators can reconcile its ID.
    module AccountNotifications
      # `AccountNotifications` owns exactly ONE group of any plan: the account
      # external copy. The direct bell and the per-report e-mail are separate
      # producers with separate permission contracts, and routing must not
      # quietly collect them into one send.
      EXTERNAL_COPY_GROUP = "external_copy"
      CHANNELS = %w(viber whatsapp messenger instagram email).freeze

      # How a routed outcome is written back onto the legacy record, so the
      # AccountNotification keeps meaning something while both ledgers exist.
      # `uncertain` maps to the legacy word `unknown`; there is no legacy
      # `expired`, and an expired payload was never sent, so it is a skip.
      #
      # Written as plain Symbols rather than `Messaging::Outcome::ACCEPTED`
      # on purpose: the pure unit suite `require_relative`s this file with no
      # Rails and no messaging constants at all, and a constant resolved in
      # the class body would make the whole suite fail to LOAD. The Outcome
      # values are exactly these symbols, and
      # test/services/decidim/bih/messaging/routed_status_vocabulary_test.rb
      # pins that they stay so.
      ROUTED_NOTIFICATION_STATUS = {
        accepted: "accepted",
        delivered: "delivered",
        rejected: "rejected",
        uncertain: "unknown",
        skipped: "skipped",
        expired: "skipped",
        failed: "unknown",
        queued: "sending",
        claimed: "sending"
      }.freeze

      class << self
        attr_accessor :template_resolver, :delivery_guard

        # rubocop:disable Metrics/ParameterLists
        def preview(user:, organization:, topic:, text: nil, template: nil, channels: CHANNELS, one_time_test: false)
          raise ArgumentError, "unknown topic" unless NotificationPreferences::TOPICS.include?(topic.to_s)

          client = Infobip::Client.new
          requested = CHANNELS & Array(channels).map(&:to_s)
          template = resolve_template(topic:, text:, template:)
          reasons = requested.index_with do |channel|
            reason_for(user:, organization:, topic:, channel:, template:, client:, one_time_test:)
          end
          eligible = reasons.select { |_channel, reason| reason.nil? }.keys
          selected = Messaging::ChannelSelection.external(eligible)
          { eligible: selected.any?, channels: selected, reasons: }
        end

        def preview_test(user:, organization:, channel:, text:)
          preview(user:, organization:, topic: :community_news, text:, channels: [channel], one_time_test: true)
        end

        # This factory is called only by the authenticated self-account action.
        # The encrypted payload records one-message permission, never a subscription.
        def enqueue_test!(user:, organization:, channel:, text:)
          raise ArgumentError, "account organization mismatch" unless user&.decidim_organization_id == organization&.id
          raise ArgumentError, "unknown channel" unless NotificationPreferences::CHANNELS.include?(channel.to_s)
          raise ArgumentError, "test content required" if text.blank?

          digest = Digest::SHA256.hexdigest("test:#{channel}:#{Time.current.to_i / 300}")
          notification = AccountNotification.create_or_find_by!(organization:, user:, deduplication_digest: digest) do |record|
            record.topic = "community_news"
            record.expires_at = 5.minutes.from_now
            record.payload = { text:, channels: [channel.to_s], template: resolve_template(topic: "community_news", text:, template: nil),
                               one_time_test_requested_by: user.id, one_time_test_requested_at: Time.current.iso8601,
                               preference_provenance: preference_provenance(user, channel) }
          end
          AccountNotificationJob.perform_later(notification.id)
          notification
        end

        # This explicitly consumes only reports for this intent's known IDs. The
        # provider returns Messages API reports once; it is never a bulk queue drain.
        def reconcile!(notification)
          return notification if notification.channels.include?("email")

          return notification unless %w(accepted unknown sending).include?(notification.status)

          client = Infobip::Client.new
          notification.provider_message_ids.each do |message_id|
            result = client.message_delivery_reports(message_id:)
            Array(result["results"]).each do |report|
              next unless report["messageId"].to_s == message_id.to_s

              notification.with_lock { apply_report(notification, report) }
              observe_attempt_report(notification, report)
            end
          end
          notification
        end

        # `message_class` is the Phase 1 REGISTRY key of the producer that owns
        # this copy — `report.author_external_copy`, not the topic
        # `report_updates`. It is the only thing that can tell `dispatch!`
        # which contract governs the intent, because several message classes
        # share one topic. An intent enqueued without one stays on the legacy
        # body no matter what any flag says.
        def enqueue!(user:, organization:, topic:, text:, deduplication_key:, template: nil,
                     channels: CHANNELS, expires_at: 24.hours.from_now, enqueue_job: true,
                     context: {}, message_class: nil)
          validate_enqueue!(user:, organization:, topic:, text:, deduplication_key:, message_class:)

          digest = Digest::SHA256.hexdigest("#{topic}:#{deduplication_key}")
          notification = AccountNotification.create_or_find_by!(organization:, user:, deduplication_digest: digest) do |record|
            record.topic = topic.to_s
            record.expires_at = expires_at
            record.payload = { text:, template: resolve_template(topic:, text:, template:), channels: Array(channels).map(&:to_s),
                               context:, message_class: message_class&.to_s,
                               notification_topic: TopicPreferences.canonical_topic(topic) }
          end
          enqueue_pending(notification) if enqueue_job
          notification
        end

        # Called by the host's existing five-minute recovery sweep. Only never-
        # attempted intents may be requeued. An abandoned send is always uncertain.
        def enqueue_pending(notification)
          return unless notification.status == "pending"

          due_at = ReportPushFollowup.scheduled_at(notification)
          if due_at && due_at > Time.current
            AccountNotificationJob.set(wait_until: due_at).perform_later(notification.id)
          else
            AccountNotificationJob.perform_later(notification.id)
          end
        end

        def recover_pending!
          AccountNotification.where(status: "sending").where(attempted_at: ...30.minutes.ago).limit(100).pluck(:id).each do |id|
            AccountNotification.where(id: id, status: "sending").update_all(status: "unknown", reason: "worker_interrupted", updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
          end
          queued = 0
          AccountNotification.where(status: "pending").where(created_at: ...1.minute.ago).find_each do |notification|
            next unless ReportPushFollowup.due?(notification)

            AccountNotificationJob.perform_later(notification.id)
            queued += 1
            break if queued >= 100
          end
        end

        # A TOPIC is not a message class. `notification.topic` is one of the
        # three MI topics; the registry keys are `report.author_external_copy`,
        # `city.service_alert_viber` and so on, and several classes share one
        # topic. Keying enrollment off the topic would make every registry
        # lookup miss and leave the routed branch as dead code that reads like a
        # feature — so the producer records its class in the payload.
        #
        # Everything unreadable, unknown or unenrolled runs {legacy_dispatch!},
        # which is the body production has always run.
        def dispatch!(notification)
          return unless ReportPushFollowup.due?(notification)

          routing = routing_enrollment(notification)
          return legacy_dispatch!(notification) if routing.nil?

          routed_dispatch!(notification, **routing)
        end

        def legacy_dispatch!(notification) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          payload = nil
          user = notification.user
          claimed = user.with_lock do
            notification.with_lock do
              next false unless notification.status == "pending"

              # The optional-traffic kill switch, read BEFORE the claim and
              # before any eligibility work: an account external copy is
              # optional traffic by definition, so this whole path is what the
              # switch governs. It is deliberately the only read of the flag
              # outside its own definition — authentication has its own path
              # and must stay reachable when optional traffic is off. Default
              # is enabled, so this branch is dead code until an operator sets
              # DECIDIM_BIH_OPTIONAL_TRAFFIC_DISABLED and restarts.
              unless Config.infobip[:optional_traffic_enabled]
                notification.update!(status: "skipped", reason: "optional_traffic_disabled", channels: [])
                next false
              end

              if notification.expires_at <= Time.current
                notification.update!(status: "skipped", reason: "expired")
                next false
              end
              payload = readable_payload(notification)
              unless payload
                notification.update!(status: "skipped", reason: "payload_unreadable")
                next false
              end
              unless legacy_topic_permitted?(notification, payload)
                notification.update!(status: "skipped", reason: "unclassified_topic_disabled", channels: [])
                next false
              end
              decision = preview(user:, organization: notification.organization, topic: notification.topic,
                                 text: payload.fetch("text"), template: payload["template"], channels: payload["channels"],
                                 one_time_test: test_intent?(notification, payload))
              unless decision[:eligible]
                notification.update!(status: "skipped", reason: "ineligible", channels: [])
                next false
              end
              notification.update!(status: "sending", attempted_at: Time.current, channels: decision[:channels])
              true
            end
          end
          return unless claimed

          # Committing the claim before HTTP avoids retrying accepted requests when
          # the worker exits between the HTTP reply and its database update.
          response = deliver(notification, payload)
          if notification.status == "sending"
            ids = message_ids(response)
            notification.update!(status: ids.empty? ? "unknown" : "accepted", provider_message_ids: ids,
                                 reason: ids.empty? ? "missing_provider_id" : nil)
            Array(response["messages"]).each { |report| apply_report(notification, report) }
            schedule_reconciliation(notification, ids)
          end
        rescue Infobip::Error => e
          notification.update!(status: e.definitive_rejection? ? "rejected" : "unknown", reason: e.error_code || "provider_error")
        rescue StandardError => e
          notification.update!(status: "unknown", reason: "dispatch_error") if notification&.persisted? && notification.status == "sending"
          Rails.logger.error("[AccountNotifications] delivery #{notification&.id}: #{e.class}")
          nil
        end

        private

        def validate_enqueue!(user:, organization:, topic:, text:, deduplication_key:, message_class:)
          raise ArgumentError, "account organization mismatch" unless user&.decidim_organization_id == organization&.id
          raise ArgumentError, "notification content required" if text.blank? || deduplication_key.blank?
          raise ArgumentError, "unknown topic" unless NotificationPreferences::TOPICS.include?(topic.to_s)
          return if message_class.nil? || Messaging::MessageClass.known?(message_class.to_s)

          raise ArgumentError, "unknown message class"
        end

        # ---- the routed body (Phase 2, compatibility mode) -------------------

        # One snapshot answers both questions, so a flag flip between them
        # cannot produce a mode and a kill switch that disagree inside one
        # dispatch.
        def routing_enrollment(notification)
          message_class = payload_message_class(notification)
          return nil if message_class.nil?

          modes = Messaging::Modes.new(organization: notification.organization)
          mode = Messaging::Enrollment.mode(organization: notification.organization, message_class:, modes:)
          return nil if mode == Messaging::Enrollment::DEFAULT_MODE

          { message_class:, mode:, modes: }
        rescue StandardError => e
          # Failing closed here means running the body production has always
          # run. A reader that cannot answer must never stop a legacy send.
          Rails.logger.warn("[AccountNotifications] enrollment unreadable, using the legacy body: #{e.class}")
          nil
        end

        def payload_message_class(notification)
          payload = readable_payload(notification)
          payload && payload["message_class"].presence
        end

        # Same shape as the legacy body, for the same reason: claim inside a
        # lock, COMMIT the claim, then perform the irreversible send. What it
        # adds is a ledger, recorded inside the claim's own transaction — so a
        # ledger failure rolls the claim back and leaves the intent pending,
        # rather than sending something nobody recorded.
        def routed_dispatch!(notification, message_class:, mode:, modes:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          unless Messaging::Enrollment.dispatch_enabled?(organization: notification.organization, message_class:, modes:)
            # A REFUSAL to act, never a fall-through to the legacy body:
            # falling back would make the kill switch send the message anyway.
            refuse_routed(notification, "dispatch_disabled")
            return
          end

          payload = nil
          group = nil
          intent = nil
          plan_context = nil
          claimed = notification.user.with_lock do
            notification.with_lock do
              next false unless notification.status == "pending"

              if notification.expires_at <= Time.current
                notification.update!(status: "skipped", reason: "expired")
                next false
              end
              payload = readable_payload(notification)
              unless payload
                notification.update!(status: "skipped", reason: "payload_unreadable")
                next false
              end
              plan_context = routing_context(notification, payload)
              plan = routing_plan(notification, payload, message_class:, mode:, context: plan_context)
              group = plan.group(EXTERNAL_COPY_GROUP)
              if group.nil?
                notification.update!(status: "skipped", reason: "ineligible", channels: [])
                next false
              end
              intent = routed_intent!(notification, payload, plan:, group:, message_class:)
              notification.update!(status: "sending", attempted_at: Time.current, channels: group.channels)
              true
            end
          end
          return unless claimed

          responses = []
          results = Messaging::RoutedDispatch.new(
            group:, intent:,
            transport: guarded_routed_transport(notification, payload, responses),
            policy_recheck: routed_recheck(notification, payload, message_class:, mode:),
            destinations: routed_destinations(plan_context)
          ).call
          settle_routed(notification, results, responses) if notification.status == "sending"
        rescue StandardError => e
          notification.update!(status: "unknown", reason: "dispatch_error") if notification&.persisted? && notification.status == "sending"
          Rails.logger.error("[AccountNotifications] routed delivery #{notification&.id}: #{e.class}")
          nil
        end

        # A terminal record is never rewritten because a flag changed.
        def refuse_routed(notification, reason)
          notification.with_lock do
            next unless notification.status == "pending"

            notification.update!(status: "skipped", reason:)
          end
        end

        def routing_plan(notification, payload, message_class:, mode:, context:)
          Messaging::Router.plan(
            message_class:, organization: notification.organization, mode:,
            recipient: routing_recipient(notification, payload), context:
          )
        end

        def routing_recipient(notification, payload)
          user = notification.user
          Messaging::RecipientContext.account(
            organization_id: notification.decidim_organization_id, account_id: user.id,
            locale: user.locale, deadline_at: notification.expires_at,
            requested_channels: Array(payload && payload["channels"])
          )
        end

        # The per-channel transport facts the legacy readers compute, handed to
        # the policy in the shape it can overlay. Flat values would be wrong in
        # both directions: a missing WhatsApp template would refuse Viber, and a
        # chat channel would be refused for having no phone.
        def routing_context(notification, payload)
          user = notification.user
          organization = notification.organization
          client = Infobip::Client.new
          template = payload && payload["template"]&.deep_symbolize_keys
          # ONE read, deliberately. The legacy body reads the delivery phone
          # exactly once here, and a second read would change how many times a
          # concurrent preference change can land between the plan, the recheck
          # and the send — which is behaviour, not bookkeeping.
          phone = VerifiedPhone.delivery_phone_for(user:, organization:)
          phone_present = phone.present?
          phone_digest = destination_digest_for(kind: "phone", value: phone)

          {
            deadline_at: notification.expires_at,
            notification_topic: TopicPreferences.canonical_topic(notification.topic),
            # The producer's own digest IS the business event's identity, so the
            # intent's deduplication scope is per event rather than per
            # (class, group, recipient) — which would make every status change
            # of every report share one scope.
            deduplication_key: notification.deduplication_digest,
            destination_present: phone_present,
            channel_context: {
              # `destination_digest` is what lets the TARGET-mode transport
              # suppression gate actually fire. Without it Policy reads a blank
              # digest and returns no reasons, so a stored provider STOP would
              # have been invisible to the very recheck that exists to honour
              # it. The digest, never the number: the raw phone is read here and
              # goes no further.
              "email" => { destination_present: user.email.present?,
                           destination_digest: destination_digest_for(kind: "email", value: user.email),
                           provider: "smtp", channel_configured: Messaging::ProactiveEmail.allowed?(user, topic: notification.topic) },
              "viber" => { destination_present: phone_present, destination_digest: phone_digest,
                           channel_configured: client.viber_business_configured? },
              "whatsapp" => { destination_present: phone_present, destination_digest: phone_digest,
                              channel_configured: whatsapp_channel_configured?(client),
                              # `== true` on purpose: `valid_template?` answers nil for a
                              # missing template, and the policy gate fires on an explicit
                              # `false`. A nil here would let an unapproved WhatsApp
                              # template through that the legacy reader refuses.
                              template_valid: valid_template?(template) == true },
              "messenger" => chat_channel_context(user:, organization:, channel: "messenger", client:),
              "instagram" => chat_channel_context(user:, organization:, channel: "instagram", client:)
            }
          }
        end

        # A destination we do not have is not a destination: it gets no digest
        # rather than a shared placeholder that would make every unreachable
        # citizen look like one identity in the suppression store.
        def destination_digest_for(kind:, value:)
          return nil if value.blank?

          Messaging::SuppressionKey.digest(kind:, value:)
        rescue ArgumentError
          nil
        end

        # The digest for the leg the router is about to attempt. The ROUTER
        # never sees an address; it is handed the already-normalized digest.
        #
        # It closes over the context the PLAN was built from rather than reading
        # the world again. Two reasons: a digest records which destination this
        # leg addressed, which is a plan-time fact; and every extra read of the
        # delivery phone is another window in which a concurrent preference
        # change lands somewhere the legacy body had no window at all.
        def routed_destinations(context)
          digests = (context[:channel_context] || {}).to_h { |channel, facts| [channel.to_s, facts[:destination_digest]] }
          lambda do |channel:, leg: nil| # rubocop:disable Lint/UnusedBlockArgument
            digest = digests[channel.to_s]
            next nil if digest.blank?

            { kind: destination_kind(channel), digest: }
          end
        end

        def whatsapp_channel_configured?(client)
          client.configured? && Config.infobip[:messages_api_enabled] && Config.infobip[:whatsapp_sender].present?
        end

        # A chat channel is addressed through a linked session, never a phone,
        # so `destination_present` is answered by the connection. That keeps the
        # three reasons in the legacy order: unconfigured, then no connection,
        # then an expired session.
        def chat_channel_context(user:, organization:, channel:, client:)
          connection = ChannelConnections.for_user(user:, organization:, channel:)
          {
            destination_present: true,
            # A chat identity is opaque and is hashed as one: parsing it as a
            # phone would let a Messenger id collide with a real handset.
            destination_digest: destination_digest_for(kind: "channel_identity", value: connection&.recipient),
            channel_configured: client.chat_channel_configured?(channel),
            connection_present: !connection.nil?,
            session_expires_at: connection&.session_expires_at
          }
        end

        # One intent per business event, FOUND before it is created: the ledger
        # has a unique index on (organization, deduplication_scope,
        # correlation_key), and a second intent for the same event would be a
        # second logical message. A genuine race loses the insert, poisons this
        # transaction and rolls the claim back — which leaves the intent pending
        # and sends nothing, the safe direction.
        def routed_intent!(notification, payload, plan:, group:, message_class:)
          correlation_key = "account_notification:#{notification.id}"
          existing = Messaging::Intent.find_by(organization: notification.organization,
                                               deduplication_scope: group.dedup_identity,
                                               correlation_key:)
          return existing if existing

          Messaging::DispatchEvidence.record_intent!(
            organization: notification.organization, message_class:,
            recipient: routing_recipient(notification, payload),
            decision: routed_decision(plan, group, message_class),
            correlation_key:, deduplication_scope: group.dedup_identity,
            account_notification: notification, expires_at: group.expires_at
          )
        end

        def routed_decision(plan, group, message_class)
          Messaging::Decision.new(
            permitted: true, message_class:, channel: group.channels.first, channel_group: group.name,
            mode: plan.mode.to_s, policy_version: plan.policy_version, eligibility_version: plan.eligibility_version,
            reason_codes: group.reason_codes, preference_origin: "router", expires_at: group.expires_at
          )
        end

        # The same provider call the legacy body makes. The whole selected
        # channel set goes in ONE request, because the provider owns the
        # failover inside it and the router never advances a channel itself.
        def guarded_routed_transport(notification, payload, responses)
          transport = routed_transport(notification, payload, responses)
          lambda do |**arguments|
            ReportPushFollowup.call(notification:, payload:) do
              if delivery_guard
                delivery_guard.call(notification:, payload:) { transport.call(**arguments) }
              else
                transport.call(**arguments)
              end
            end
          end
        end

        def routed_transport(notification, payload, responses)
          lambda do |channel:, channels:, group:, leg: nil| # rubocop:disable Lint/UnusedBlockArgument
            user = notification.user
            organization = notification.organization
            client = Infobip::Client.new
            response = if channels == ["email"]
                         user.with_lock { deliver_email(notification) }
                       elsif channels.intersect?(%w(viber whatsapp))
                         client.send_phone_message(to: VerifiedPhone.delivery_phone_for(user:, organization:),
                                                   text: payload.fetch("text"),
                                                   whatsapp_template: payload["template"]&.deep_symbolize_keys,
                                                   channels: channels.map(&:to_sym), expires_at: group.expires_at,
                                                   final_sms: false,
                                                   channel_validity_seconds: Infobip::Client::CAMPAIGN_CHANNEL_VALIDITY)
                       else
                         connection = ChannelConnections.for_user(user:, organization:, channel:)
                         client.send_chat_text(channel:, to: connection.recipient, text: payload.fetch("text"))
                       end
            responses << response
            response
          end
        end

        # Evaluated INSIDE the claim, immediately before the irreversible send,
        # from freshly read preference and reachability state — the routed
        # equivalent of the legacy recheck in `deliver_to_account`.
        def routed_recheck(notification, payload, message_class:, mode:)
          lambda do |channel:|
            notification.user.reload
            Messaging::Policy.decide(
              organization: notification.organization, message_class:, channel:,
              recipient: routing_recipient(notification, payload),
              context: routing_context(notification, payload), mode:
            )
          end
        end

        def settle_routed(notification, results, responses)
          outcome = results.map(&:outcome).reduce(nil) { |merged, value| Messaging::Outcome.merge(merged, value) }
          status = ROUTED_NOTIFICATION_STATUS.fetch(outcome, "unknown")
          ids = results.flat_map(&:provider_ids).compact.uniq

          notification.update!(status:, provider_message_ids: ids,
                               reason: status == "accepted" ? nil : results.filter_map(&:reason).first,
                               delivered_at: status == "delivered" ? Time.current : notification.delivered_at)
          # Same order as the legacy body: settle, then apply any report the
          # send response already carried, then schedule reconciliation.
          apply_send_responses(notification, responses)
          schedule_reconciliation(notification, ids)
        end

        def schedule_reconciliation(notification, ids)
          return if notification.channels.include?("email")
          return unless ids.any? && notification.status == "accepted"

          AccountNotificationReconciliationJob.set(wait: 1.minute).perform_later(notification.id, 0)
        end

        def destination_kind(channel)
          return "email" if channel.to_s == "email"

          %w(viber whatsapp sms).include?(channel.to_s) ? "phone" : "channel_identity"
        end

        def apply_send_responses(notification, responses)
          responses.each do |response|
            Array(response.is_a?(Hash) ? response["messages"] : nil).each { |report| apply_report(notification, report) }
          end
        end

        # ---- the legacy body -------------------------------------------------

        # Catch only envelope decoding failures here. Database failures must
        # remain recoverable; they do not prove that a citizen's intent is bad.
        def readable_payload(notification)
          payload = notification.payload
          return unless valid_payload_shape?(payload)

          payload
        rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError, TypeError
          # A purpose-mismatched envelope decrypts to nil, which JSON.parse
          # rejects with TypeError. No database operation happens in this reader.
          nil
        end

        # An unknown message class means an intent enqueued by code this
        # registry no longer describes. The honest answer is to refuse the
        # payload rather than route it under a contract nobody can name.
        def valid_payload_shape?(payload)
          return false unless payload.is_a?(Hash) && payload["text"].is_a?(String) && payload["text"].present?
          return false unless payload["channels"].is_a?(Array) && (payload["channels"] - CHANNELS).empty?
          return false unless payload["template"].nil? || payload["template"].is_a?(Hash)

          payload["message_class"].nil? || Messaging::MessageClass.known?(payload["message_class"].to_s)
        end

        # A report belongs to ONE LEG, and the leg is found by the provider id
        # the report carries — not by the intent as a whole. One provider-managed
        # chain answers with one id per channel, so "attach it to the intent"
        # would credit a Viber delivery report to a WhatsApp leg, or to whichever
        # attempt happened to be first.
        #
        # {Attempt#observe!} merges rather than assigns, so a late
        # PENDING_ENROUTE cannot downgrade a delivered leg and nothing here can
        # reset an uncertain attempt to pending.
        def observe_attempt_report(notification, report)
          message_id = report["messageId"].to_s
          return if message_id.empty?

          attempt = Messaging::Attempt
                    .joins(:intent)
                    .where(decidim_bih_messaging_intents: { decidim_bih_account_notification_id: notification.id })
                    .for_provider_message(message_id).first
          return if attempt.nil?

          attempt.observe!(outcome: Messaging::Outcome.classify(report:, previous: attempt.status.to_sym),
                           reason: report.dig("status", "name"))
        rescue StandardError => e
          # Reconciliation is an observation. Losing one must never turn into a
          # failed job that retries a send.
          Rails.logger.warn("[messaging] attempt report #{e.class}")
        end

        def apply_report(notification, report)
          status = report.fetch("status", {})
          if status["name"] == "DELIVERED_TO_HANDSET"
            notification.update!(status: "delivered", delivered_at: Time.current, reason: nil)
          elsif %w(REJECTED UNDELIVERABLE EXPIRED).include?(status["groupName"]) && notification.status != "delivered"
            # A failed primary is not failure of a still-running managed chain.
            terminal = notification.channels.one? && notification.provider_message_ids.one?
            notification.update!(status: terminal ? "failed" : notification.status,
                                 reason: "provider_#{status["groupName"].downcase}")
          end
        end

        def test_intent?(notification, payload)
          channel = Array(payload["channels"]).first
          payload["one_time_test_requested_by"] == notification.decidim_user_id &&
            payload["one_time_test_requested_at"].present? && notification.expires_at <= notification.created_at + 6.minutes &&
            payload["preference_provenance"] == preference_provenance(notification.user, channel)
        end

        # Older pending community intents carried no producer classification.
        # They may have been a platform campaign or a neighborhood broadcast;
        # preserve all relevant refusals instead of guessing which topic won.
        def legacy_topic_permitted?(notification, payload)
          return true unless notification.topic == "community_news" && payload["notification_topic"].blank? && payload["message_class"].blank?
          return true if test_intent?(notification, payload)

          %w(community_news platform_news neighborhood_info).all? do |topic|
            TopicPreferences.enabled?(notification.user, topic:)
          end
        end

        def preference_provenance(user, _channel)
          Messaging::Preference.find_by(organization: user.organization, user:, topic: "community_news")&.change_id
        end

        def resolve_template(topic:, text:, template:)
          value = template || template_resolver&.call(topic: topic.to_s, text:)
          value&.deep_symbolize_keys
        end

        def reason_for(user:, organization:, topic:, channel:, template:, client:, one_time_test:)
          return "account_unavailable" unless account_available?(user, organization)
          return "permission_required" unless one_time_test || NotificationPreferences.permitted?(user, topic:, channel:)

          return Messaging::ProactiveEmail.allowed?(user, topic:) ? nil : "email_unavailable" if channel == "email"
          return "transport_suppressed" if transport_suppressed?(user:, organization:, channel:)

          if %w(viber whatsapp).include?(channel)
            phone_reason(user:, organization:, channel:, template:, client:)
          else
            social_reason(user:, organization:, channel:, client:)
          end
        end

        def account_available?(user, organization)
          user && organization && user.decidim_organization_id == organization.id && !user.deleted? && !user.blocked?
        end

        def transport_suppressed?(user:, organization:, channel:)
          phone_channel = %w(viber whatsapp).include?(channel.to_s)
          destination = if phone_channel
                          VerifiedPhone.delivery_phone_for(user:, organization:)
                        else
                          ChannelConnections.for_user(user:, organization:, channel:)&.recipient
                        end
          return false if destination.blank?

          digest = Messaging::SuppressionKey.digest(kind: phone_channel ? "phone" : "channel_identity", value: destination)
          Messaging::Suppression.blocking_for(organization:, provider: "infobip", channel: channel.to_s, destination_digest: digest).present?
        end

        def valid_template?(template)
          template && template[:name].present? && template[:language].present? && template[:body].is_a?(Hash)
        end

        def phone_reason(user:, organization:, channel:, template:, client:)
          return "verified_phone_required" if VerifiedPhone.delivery_phone_for(user:, organization:).blank?
          return client.viber_business_configured? ? nil : "channel_unconfigured" if channel == "viber"
          return "template_required" unless valid_template?(template)
          return "channel_unconfigured" unless client.configured? && Config.infobip[:messages_api_enabled] && Config.infobip[:whatsapp_sender].present?

          nil
        end

        def social_reason(user:, organization:, channel:, client:)
          return "channel_unconfigured" unless client.chat_channel_configured?(channel)

          connection = ChannelConnections.for_user(user:, organization:, channel:)
          return "connection_required" unless connection
          return "session_expired" unless connection.session_expires_at && connection.session_expires_at > Time.current

          nil
        end

        def deliver(notification, payload)
          ReportPushFollowup.call(notification:, payload:) do
            if delivery_guard
              delivery_guard.call(notification:, payload:) { deliver_to_account(notification, payload) }
            else
              deliver_to_account(notification, payload)
            end
          end
        end

        def deliver_to_account(notification, payload)
          # Recheck after claiming and immediately before HTTP; preference and phone
          # mutations use the same user lock, including disconnect and revocation.
          notification.user.with_lock do
            # A worker may wait between committing its claim and acquiring this
            # final lock. The intent's deadline still applies to every transport.
            if notification.expires_at <= Time.current
              notification.update!(status: "skipped", reason: "expired")
              next nil
            end
            unless legacy_topic_permitted?(notification, payload)
              notification.update!(status: "skipped", reason: "unclassified_topic_disabled")
              next nil
            end
            decision = preview(user: notification.user, organization: notification.organization, topic: notification.topic,
                               text: payload.fetch("text"), template: payload["template"], channels: notification.channels, one_time_test: test_intent?(notification, payload))
            unless decision[:eligible]
              notification.update!(status: "skipped", reason: "eligibility_changed")
              next nil
            end
            client = Infobip::Client.new
            channels = decision[:channels]
            notification.update!(channels:)
            if channels == ["email"]
              deliver_email(notification)
            elsif channels.intersect?(%w(viber whatsapp))
              client.send_phone_message(to: VerifiedPhone.delivery_phone_for(user: notification.user, organization: notification.organization),
                                        text: payload.fetch("text"), whatsapp_template: payload["template"]&.deep_symbolize_keys,
                                        channels: channels.map(&:to_sym), expires_at: notification.expires_at, final_sms: false,
                                        channel_validity_seconds: Infobip::Client::CAMPAIGN_CHANNEL_VALIDITY)
            else
              channel = channels.first
              connection = ChannelConnections.for_user(user: notification.user, organization: notification.organization, channel:)
              client.send_chat_text(channel:, to: connection.recipient, text: payload.fetch("text"))
            end
          end
        end

        def deliver_email(notification)
          raise ArgumentError, "expired notification" if notification.expires_at <= Time.current
          raise ArgumentError, "email is no longer eligible" unless Messaging::ProactiveEmail.allowed?(notification.user, topic: notification.topic)

          report_message = ReportMessage.find_by(account_notification: notification, actor_role: "staff")
          message = if report_message && report_message.report.author == notification.user && report_message.report.organization == notification.organization
                      ReporterMailer.case_message(report_message).deliver_now
                    else
                      AccountNotificationMailer.notification(notification).deliver_now
                    end
          raise IOError, "SMTP did not accept a message" unless message && message.message_id.present?

          { "messages" => [{ "messageId" => "smtp:#{message.message_id}" }] }
        end

        def message_ids(response)
          return [] unless response.is_a?(Hash)

          Array(response["messages"] || response[:messages]).filter_map { |message| message["messageId"] || message[:messageId] }.map(&:to_s).uniq
        end
        # rubocop:enable Metrics/ParameterLists
      end
    end
  end
end

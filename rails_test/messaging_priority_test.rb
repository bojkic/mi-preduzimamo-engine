# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Task 2.7: priority is capacity and deadlines, never permission.
      #
      # The pure suite (test/services/decidim/bih/messaging/priority_test.rb)
      # owns the DST, starvation and expiry arithmetic. This file proves the
      # three things a pure suite structurally cannot:
      #
      #   * the reserved authentication queue is the queue the JOB actually
      #     enqueues to, and optional work does not share it;
      #   * a queue retry of a leg that already reached the provider does not
      #     produce a second paid send, against the real Phase 1 ledger;
      #   * the host configuration layer is genuinely inert today, and the
      #     window works when a host sets it.
      class MessagingPriorityTest < ActiveSupport::TestCase
        # Resolved lazily: a missing constant in a class body aborts the whole
        # harness at LOAD time, turning one red test into "no tests ran".
        def priority = Decidim::Bih::Messaging::Priority

        def outcome_module = Decidim::Bih::Messaging::Outcome

        def registry = Decidim::Bih::Messaging::MessageClass

        ROUTINE_CLASS = "city.service_alert_viber"
        AUTHENTICATION_CLASS = "authentication.phone_verification"

        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        class StubTransport
          attr_reader :calls

          def initialize(script)
            @script = script
            @calls = []
          end

          def call(channel:, channels:, group:, leg: nil)
            @calls << { channel: channel.to_s, channels: Array(channels).map(&:to_s),
                        endpoint_ref: leg && leg[:endpoint_ref], group: group.name }
            scripted = @script.fetch(channel.to_sym)
            raise scripted if scripted.is_a?(StandardError)

            scripted
          end
        end

        Refusal = Struct.new(:reason_codes) do
          def permitted? = false
        end

        def definitive(code) = Decidim::Bih::Infobip::Error.new("refused", http_status: 400, error_code: code)

        def uncertain(code) = Decidim::Bih::Infobip::Error.new("no reply", error_code: code)

        def accepted(id) = { "messages" => [{ "messageId" => id }] }

        def intent!(message_class: ROUTINE_CLASS)
          Decidim::Bih::Messaging::Intent.create!(
            organization: @organization, message_class:, recipient_kind: "account", user: @citizen,
            correlation_key: SecureRandom.hex(10), deduplication_scope: "priority-harness",
            policy_version: "p1", eligibility_version: "e1", mode: "compatibility", status: "evaluated"
          )
        end

        # rubocop:disable Metrics/ParameterLists
        def routine_group(channels:, strategy: :sequential, group_mode: "fallback", fanout: "per_recipient",
                          legs: [], expires_at: nil, name: "external_copy")
          Decidim::Bih::Messaging::DeliveryGroup.new(
            name:, channels: Array(channels).map(&:to_s), legs:, group_mode:, fanout:,
            attempt_strategy: strategy, content_variant: "city_alert", content_variant_by_channel: {},
            locale: "sr", template: nil, expires_at: expires_at || 1.hour.from_now,
            dedup_identity: "#{ROUTINE_CLASS}:#{name}:1", dedup_owner: "ledger",
            timeout_policy: Decidim::Bih::Messaging::Router::TIMEOUT_POLICY, fallback_owner: "producer",
            terminates_siblings: false, priority: "routine", preference_adapter: "city_service_alerts_topic",
            reason_codes: []
          ).frozen_copy
        end
        # rubocop:enable Metrics/ParameterLists

        def dispatch(group, transport, intent:, policy_recheck: nil)
          Decidim::Bih::Messaging::RoutedDispatch.new(group:, intent:, transport:, policy_recheck:).call
        end

        def with_quiet_hours(window)
          previous = Decidim::Bih.routine_quiet_hours
          Decidim::Bih.routine_quiet_hours = window
          yield
        ensure
          Decidim::Bih.routine_quiet_hours = previous
        end

        def with_budgets(budgets)
          previous = Decidim::Bih.routine_budgets
          Decidim::Bih.routine_budgets = budgets
          yield
        ensure
          Decidim::Bih.routine_budgets = previous
        end

        # ---- reserved capacity ------------------------------------------------

        test "authentication work goes to its own queue and optional work does not share it" do
          assert_equal "authentication_critical", Decidim::Bih::Infobip::SendPhoneMessageJob.new.queue_name
          assert_equal "integrations", Decidim::Bih::AccountNotificationJob.new.queue_name
          assert_not_equal Decidim::Bih::Infobip::SendPhoneMessageJob.new.queue_name,
                           Decidim::Bih::AccountNotificationJob.new.queue_name
        end

        test "the queue each job uses is the one the registry's priority chooses" do
          assert_equal :authentication_critical, priority.queue_for(registry.fetch(AUTHENTICATION_CLASS))
          assert_equal :integrations, priority.queue_for(registry.fetch(ROUTINE_CLASS))
          assert_equal priority.queue_for(registry.fetch(AUTHENTICATION_CLASS)).to_s,
                       Decidim::Bih::Infobip::SendPhoneMessageJob.new.queue_name
          assert_equal priority.queue_for(registry.fetch(ROUTINE_CLASS)).to_s,
                       Decidim::Bih::AccountNotificationJob.new.queue_name
        end

        # Capacity is all the reservation buys. Every anti-abuse budget that
        # guards the authentication surfaces is pinned here, so a later change
        # that "makes verification faster" by relaxing one of them fails.
        test "reserving authentication capacity relaxes none of its anti-abuse throttles" do
          rules = Decidim::Bih.required_public_throttles.index_by { |rule| rule[:id] }

          assert_equal [5, 900], rules.fetch("phone_verification.change_by_session").values_at(:limit, :period)
          assert_equal [10, 60], rules.fetch("phone_verification.code_by_session").values_at(:limit, :period)
          assert_equal [5, 900], rules.fetch("phone_verification.resend_by_session").values_at(:limit, :period)
          assert_equal [3, 900], rules.fetch("phone_login.request_by_phone").values_at(:limit, :period)
          assert_equal 5, Decidim::Bih::PhoneVerification::AttemptLimiter::MAX_ATTEMPTS
        end

        # ---- no duplicate send under a queue retry ---------------------------

        test "a Sidekiq retry of an accepted leg does not produce a second paid send" do
          intent = intent!
          transport = StubTransport.new(viber: accepted("m1"))
          group = routine_group(channels: %w(viber))

          first = dispatch(group, transport, intent:)
          second = dispatch(group, transport, intent:)

          assert_equal 1, transport.calls.size, "the claim is committed before the send; a retry must find it claimed"
          assert_equal 1, intent.attempts.reload.count
          assert_equal outcome_module::ACCEPTED, first.last.outcome
          assert_equal outcome_module::ACCEPTED, second.last.outcome
          assert_equal "already_attempted", second.last.reason, "a replay says so rather than looking like a fresh send"
          assert_equal %w(m1), second.last.provider_ids
        end

        test "an unknown outcome is not retried into a second attempt by the queue" do
          intent = intent!
          transport = StubTransport.new(viber: uncertain("EC_TIMEOUT"), whatsapp: accepted("m2"))
          group = routine_group(channels: %w(viber whatsapp))

          dispatch(group, transport, intent:)
          replayed = dispatch(group, transport, intent:)

          assert_equal(%w(viber), transport.calls.map { |call| call[:channel] })
          assert_equal 1, intent.attempts.reload.count
          assert_equal %w(uncertain), intent.attempts.map(&:status)
          assert_equal outcome_module::UNCERTAIN, replayed.last.outcome
          refute outcome_module.authorizes_fallback?(replayed.last.outcome),
                 "an uncertain outcome is what stops the chain; nothing here may reimplement that rule"
        end

        # The chain already ran. A retry must not run it again, in either
        # direction: not the rejected leg, and not the accepted one after it.
        test "a retry after a definitive rejection does not re-drive the chain" do
          intent = intent!
          transport = StubTransport.new(viber: definitive("EC_NOT_REACHABLE"), whatsapp: accepted("m1"))
          group = routine_group(channels: %w(viber whatsapp))

          dispatch(group, transport, intent:)
          dispatch(group, transport, intent:)

          assert_equal(%w(viber whatsapp), transport.calls.map { |call| call[:channel] })
          assert_equal 2, intent.attempts.reload.count
          assert(intent.attempts.map(&:status).none? { |status| status == "queued" })
        end

        test "a per-device retry sends to each endpoint exactly once, and never to a fourth" do
          intent = intent!
          transport = StubTransport.new(push: accepted("m1"))
          legs = %w(ep-a ep-b ep-c).map { |ref| { endpoint_ref: ref, outcome: outcome_module::QUEUED } }
          group = routine_group(channels: %w(push), strategy: :parallel, group_mode: "parallel",
                                fanout: "per_device", legs:, name: "push")

          dispatch(group, transport, intent:)
          dispatch(group, transport, intent:)

          assert_equal(%w(ep-a ep-b ep-c), transport.calls.map { |call| call[:endpoint_ref] })
          assert_equal 3, intent.attempts.reload.count
        end

        # The mirror image, and the reason the guard lists STATUSES rather than
        # blocking on any row at all: a leg the transport was provably never
        # reached for is still retryable, or a transient policy refusal would
        # silently become permanent.
        test "a leg the transport never reached may still be retried" do
          intent = intent!
          transport = StubTransport.new(viber: accepted("m1"))
          group = routine_group(channels: %w(viber))
          refuse = ->(channel:) { Refusal.new([:transport_suppressed]) } # rubocop:disable Lint/UnusedBlockArgument

          skipped = dispatch(group, transport, intent:, policy_recheck: refuse)

          assert_empty transport.calls
          assert_equal outcome_module::SKIPPED, skipped.last.outcome

          retried = dispatch(group, transport, intent:)

          assert_equal 1, transport.calls.size
          assert_equal outcome_module::ACCEPTED, retried.last.outcome
        end

        # Provider/queue latency: a leg whose deadline passed while it waited is
        # EXPIRED before anything is claimed, and the transport is never reached.
        # Deadlines are the other half of what priority controls, and they are
        # enforced at dispatch time rather than trusted from enqueue time.
        test "a group whose deadline passed while it waited in the queue is never sent" do
          intent = intent!
          transport = StubTransport.new(viber: accepted("m1"))
          group = routine_group(channels: %w(viber), expires_at: 1.second.ago)

          results = dispatch(group, transport, intent:)

          assert_empty transport.calls
          assert_equal outcome_module::EXPIRED, results.last.outcome
          assert_equal "expired", results.last.reason
          assert_equal 0, intent.attempts.reload.count, "an expired leg is not claimed, so it costs nothing"
        end

        # A slow provider is an UNCERTAIN outcome, and uncertainty is the one
        # thing that must never become a second paid message.
        test "a provider that never answers stops the chain instead of advancing it" do
          intent = intent!
          transport = StubTransport.new(viber: uncertain("EC_TIMEOUT"), whatsapp: accepted("m2"))
          group = routine_group(channels: %w(viber whatsapp))

          results = dispatch(group, transport, intent:)

          assert_equal 1, transport.calls.size
          assert_equal outcome_module::UNCERTAIN, results.last.outcome
          refute outcome_module.authorizes_fallback?(results.last.outcome)
          assert_equal :uncertain_no_retry, group.timeout_policy
        end

        # ---- the window is inert on deploy -----------------------------------

        test "no quiet-hours window is configured, so nothing is delayed" do
          assert_nil Decidim::Bih.routine_quiet_hours
          assert_empty Decidim::Bih.routine_budgets

          group = routine_group(channels: %w(viber))
          now = Time.find_zone!("Europe/Sarajevo").local(2026, 9, 14, 23, 30).utc

          assert_equal now, priority.deliverable_at(group:, now:, window: Decidim::Bih.routine_quiet_hours,
                                                    priority: group.priority)
        end

        test "the registry's own priority is what decides whether a group may be deferred" do
          assert_equal "routine", registry.fetch(ROUTINE_CLASS).priority
          assert_equal "authentication", registry.fetch(AUTHENTICATION_CLASS).priority
          assert priority.deferrable?(registry.fetch(ROUTINE_CLASS).priority)
          refute priority.deferrable?(registry.fetch(AUTHENTICATION_CLASS).priority)
        end

        # Wave A put the D8 hook on DeliveryGroup. Two statements of one rule, so
        # they are pinned to each other over every priority the registry has —
        # including `bulk`, which D8 does not mention and which therefore does
        # NOT defer. That gap is recorded in the Phase 2 binding doc rather than
        # closed by inference.
        test "the group's own D8 hook and Priority.deferrable? agree on every registry priority" do
          registry_priorities = Decidim::Bih::Messaging::MessageClass::PRIORITIES

          assert_equal %w(authentication transactional routine bulk), registry_priorities
          registry_priorities.each do |value|
            group = Decidim::Bih::Messaging::DeliveryGroup.new(priority: value)

            assert_equal priority.deferrable?(value), group.quiet_hours_deferrable?,
                         "#{value}: the group hook and the priority rule disagree"
          end
          refute priority.deferrable?("bulk"), "D8 names routine only; bulk is an open question, not an inference"
        end

        test "a host that sets D8's window defers routine work and expires what would go stale" do
          with_quiet_hours(Decidim::Bih::Messaging::Priority::D8_QUIET_HOURS) do
            window = Decidim::Bih.routine_quiet_hours
            now = Time.find_zone!("Europe/Sarajevo").local(2026, 9, 14, 23, 30).utc
            fresh = routine_group(channels: %w(viber), expires_at: now + (12 * 3600))
            stale = routine_group(channels: %w(viber), expires_at: now + 1800)

            assert_equal Time.find_zone!("Europe/Sarajevo").local(2026, 9, 15, 8, 0).utc,
                         priority.deliverable_at(group: fresh, now:, window:, priority: fresh.priority)
            assert_nil priority.deliverable_at(group: stale, now:, window:, priority: stale.priority),
                       "a city notice must expire rather than arrive obsolete at 08:00"
          end

          assert_nil Decidim::Bih.routine_quiet_hours, "the window is restored; this release ships with none"
        end

        test "a configured window never reaches an authentication message" do
          with_quiet_hours(Decidim::Bih::Messaging::Priority::D8_QUIET_HOURS) do
            now = Time.find_zone!("Europe/Sarajevo").local(2026, 9, 14, 23, 30).utc
            entry = registry.fetch(AUTHENTICATION_CLASS)

            assert_equal now, priority.deliverable_at(group: routine_group(channels: %w(viber)), now:,
                                                      window: Decidim::Bih.routine_quiet_hours,
                                                      priority: entry.priority)
          end
        end

        test "budget_for reads the host configuration and an unconfigured class has no budget" do
          with_budgets("default" => { max_messages: 50, period_seconds: 600 },
                       ROUTINE_CLASS => { max_messages: 100, period_seconds: 3600 }) do
            budget = priority.budget_for(organization: @organization, message_class: registry.fetch(ROUTINE_CLASS))

            assert_equal 100, budget[:max_messages]
            assert_equal 3600, budget[:period_seconds]
            assert_equal 50, priority.budget_for(organization: @organization,
                                                 message_class: "operator.direct_message")[:max_messages]
          end

          assert_empty priority.budget_for(organization: @organization, message_class: registry.fetch(ROUTINE_CLASS))
        end

        test "an exhausted budget delays inside the lifetime and expires beyond it, never refuses" do
          now = Time.utc(2026, 9, 14, 12, 0)
          budget = { max_messages: 10, period_seconds: 1800 }
          release = priority.budget_release_at(budget:, now:, sent: 10)

          assert_equal now + 1800, release
          fresh = routine_group(channels: %w(viber), expires_at: now + 3600)

          assert_equal release, priority.deliverable_at(group: fresh, now:, window: nil,
                                                        priority: "routine", budget_release_at: release)
          assert_nil priority.deliverable_at(group: routine_group(channels: %w(viber), expires_at: now + 600),
                                             now:, window: nil, priority: "routine", budget_release_at: release)
        end
      end
    end
  end
end

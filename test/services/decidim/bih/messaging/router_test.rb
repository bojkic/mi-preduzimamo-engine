# frozen_string_literal: true

require "test_helper"
# Real Phase 1 collaborators wherever they are loadable without Rails. Only the
# Policy is a double, because deciding needs the database — and even that double
# returns REAL Decision objects.
require_relative "../../../../../app/services/decidim/bih/messaging/message_class"
require_relative "../../../../../app/services/decidim/bih/messaging/recipient_context"
require_relative "../../../../../app/services/decidim/bih/messaging/decision"
require_relative "../../../../../app/services/decidim/bih/messaging/outcome"
require_relative "../../../../../app/services/decidim/bih/messaging/delivery_group"
require_relative "../../../../../app/services/decidim/bih/messaging/routing_plan"
require_relative "../../../../../app/services/decidim/bih/messaging/channel_selection"
require_relative "../../../../../app/services/decidim/bih/messaging/router"

module Decidim
  module Bih
    module Messaging
      class RouterTest < Minitest::Test
        Org = Struct.new(:id)

        # Registry keys, not topic names. `report.case_message_to_author` is the
        # three-group case (bell + push + external copy) the roadmap's "a
        # successful bell must not terminate a phone chain" rule is about.
        THREE_GROUP = "report.case_message_to_author"
        SINGLE_CHANNEL = "city.service_alert_viber"

        # Returns real Decision objects so every reader the router uses is the
        # production one. `allow` is the set of channels this policy permits.
        class FakePolicy
          attr_reader :calls

          def initialize(allow:, expires_at: nil, reasons: [:preference_blocked])
            @allow = Array(allow).map(&:to_s)
            @expires_at = expires_at
            @reasons = reasons
            @calls = []
          end

          # The signature mirrors Policy.decide exactly, unused arguments
          # included: a double that accepts a narrower call would let the
          # router drift away from the real entry point unnoticed.
          # rubocop:disable Metrics/ParameterLists, Lint/UnusedMethodArgument
          def decide(organization:, message_class:, recipient:, channel:, context: {}, mode: nil, **_rest)
            @calls << channel.to_s
            permitted = @allow.include?(channel.to_s)
            Decision.new(
              permitted:, message_class: message_class.to_s, channel: channel.to_s, mode: mode.to_s,
              policy_version: "p1", eligibility_version: "e1",
              reason_codes: permitted ? [] : @reasons,
              preference_origin: "organization_default",
              expires_at: @expires_at
            )
          end
          # rubocop:enable Metrics/ParameterLists, Lint/UnusedMethodArgument
        end

        def setup
          @org = Org.new(1)
          @now = Time.at(1_789_000_000).utc
          @recipient = RecipientContext.account(organization_id: 1, account_id: 42, locale: "sr")
        end

        def plan_for(key, policy, **overrides)
          Router.plan(message_class: key, recipient: @recipient, organization: @org,
                      context: {}, mode: :compatibility, policy:, now: @now, **overrides)
        end

        # ---- independence -----------------------------------------------------

        def test_bell_push_and_the_external_copy_are_three_independent_groups
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell push viber whatsapp)))

          assert_equal %w(bell push external_copy), plan.groups.map(&:name)
          assert plan.groups.none?(&:terminates_siblings), "no group may cancel a sibling"
        end

        def test_a_blocked_external_copy_leaves_the_bell_and_push_groups_standing
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell push)))

          assert_equal %w(bell push), plan.groups.map(&:name)
          assert_includes plan.suppressed.map { |s| s[:group] }, "external_copy"
        end

        def test_a_blocked_channel_is_removed_from_its_group_with_a_reason_not_silently
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell push viber)))
          external = plan.groups.find { |g| g.name == "external_copy" }

          assert_equal %w(viber), external.channels
          suppressed = plan.suppressed.select { |s| s[:group] == "external_copy" }

          assert_includes suppressed.map { |s| s[:channel] }, "whatsapp"
          assert_includes suppressed.find { |s| s[:channel] == "whatsapp" }[:reason_codes], :preference_blocked
        end

        def test_a_group_with_no_permitted_channel_is_dropped_and_every_channel_is_recorded
          plan = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: []))

          assert_empty plan.groups
          assert_equal(MessageClass::TOPIC_CHANNELS, plan.suppressed.map { |entry| entry[:channel] })
        end

        # ---- the legacy "one chain OR one session" rule -----------------------

        def test_a_single_group_prefers_an_eligible_live_session_over_paid_channels
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(viber whatsapp messenger instagram)))
          external = plan.groups.find { |g| g.name == "external_copy" }

          assert_equal %w(messenger), external.channels
          not_selected = plan.suppressed.select { |s| s[:reason_codes].include?(:not_selected_single_group) }

          assert_equal(%w(viber whatsapp instagram), not_selected.map { |s| s[:channel] })
        end

        def test_a_single_group_falls_back_to_exactly_one_linked_session
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(messenger instagram)))
          external = plan.groups.find { |g| g.name == "external_copy" }

          assert_equal %w(messenger), external.channels
          assert_includes plan.suppressed.select { |s| s[:channel] == "instagram" }.first[:reason_codes],
                          :not_selected_single_group
        end

        def test_a_single_group_is_one_request_the_provider_owns_not_a_router_loop
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(viber whatsapp)))
          external = plan.groups.find { |g| g.name == "external_copy" }

          assert_equal :single_request, external.attempt_strategy
          refute_predicate external, :sequential?
        end

        # ---- fanout ------------------------------------------------------------

        def test_push_fanout_is_parallel_and_one_leg_per_endpoint
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(push)),
                          context: { push_endpoint_refs: %w(dev-a dev-b dev-c) })
          push = plan.groups.find { |g| g.name == "push" }

          assert_predicate push, :parallel?
          assert_equal :parallel, push.attempt_strategy
          assert_equal 3, push.legs.size
          assert_equal(%w(dev-a dev-b dev-c), push.legs.map { |leg| leg[:endpoint_ref] })
          assert(push.legs.all? { |leg| leg[:outcome] == Outcome::QUEUED })
        end

        def test_a_group_that_is_not_per_device_has_no_legs
          plan = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: %w(viber)))

          assert_empty plan.groups.first.legs
        end

        # ---- caller restrictions ----------------------------------------------

        def test_a_caller_restriction_survives_routing
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell push viber whatsapp)),
                          requested_channels: %w(bell viber))

          assert_equal %w(bell external_copy), plan.groups.map(&:name)
          assert_equal %w(viber), plan.groups.last.channels
          assert_includes plan.suppressed.select { |s| s[:channel] == "whatsapp" }.first[:reason_codes],
                          :caller_restricted
        end

        def test_a_requested_channel_the_policy_refuses_is_not_added_back
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(viber)),
                          requested_channels: %w(viber whatsapp))

          assert_equal %w(viber), plan.groups.first.channels
        end

        def test_requested_channels_are_taken_off_the_recipient_when_the_caller_passes_none
          restricted = RecipientContext.account(organization_id: 1, account_id: 42, locale: "sr",
                                                requested_channels: %w(viber))
          plan = Router.plan(message_class: THREE_GROUP, recipient: restricted, organization: @org,
                             context: {}, mode: :compatibility,
                             policy: FakePolicy.new(allow: %w(bell push viber whatsapp)), now: @now)

          assert_equal %w(external_copy), plan.groups.map(&:name)
          assert_equal %w(viber), plan.groups.first.channels
        end

        def test_an_explicit_empty_restriction_permits_nothing
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell viber)), requested_channels: [])

          assert_empty plan.groups
        end

        # ---- expiry -------------------------------------------------------------

        def test_expiry_is_the_earliest_of_class_context_and_decision
          plan = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: %w(viber), expires_at: @now + 3600),
                          context: { deadline_at: @now + 1800 })

          assert_equal @now + 1800, plan.groups.first.expires_at
        end

        def test_a_decision_expiry_earlier_than_the_class_ttl_wins
          plan = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: %w(viber), expires_at: @now + 600))

          assert_equal @now + 600, plan.groups.first.expires_at
        end

        def test_the_class_ttl_applies_when_nothing_else_is_given
          plan = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: %w(viber)))

          assert_equal @now + 86_400, plan.groups.first.expires_at
        end

        def test_an_already_expired_plan_produces_no_groups
          plan = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: %w(viber)),
                          context: { deadline_at: @now - 1 })

          assert_empty plan.groups
          assert_includes plan.suppressed.flat_map { |s| s[:reason_codes] }, :expired
        end

        # ---- identity, versions, content ---------------------------------------

        def test_dedup_identity_is_per_group_not_per_plan
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell push viber)),
                          context: { deduplication_key: "report:7:resolved" })

          assert_equal 3, plan.groups.map(&:dedup_identity).uniq.size
          assert(plan.groups.all? { |g| g.dedup_identity.include?(THREE_GROUP) })
          assert(plan.groups.all? { |g| g.dedup_identity.include?("report:7:resolved") })
        end

        def test_versions_from_the_decision_are_carried_on_the_plan
          plan = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: %w(viber)))

          assert_equal "p1", plan.policy_version
          assert_equal "e1", plan.eligibility_version
        end

        def test_the_whatsapp_report_variant_is_not_the_viber_report_variant
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(viber whatsapp)))
          external = plan.groups.find { |g| g.name == "external_copy" }

          assert_equal "full_case_text", external.content_variant_for("viber")
          assert_equal "reference_and_status_only", external.content_variant_for("whatsapp")
          refute_equal external.content_variant_for("viber"), external.content_variant_for("whatsapp")
        end

        def test_a_channel_without_its_own_variant_uses_the_group_default
          plan = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: %w(viber)))

          assert_equal "city_alert", plan.groups.first.content_variant_for("viber")
        end

        def test_the_locale_comes_from_the_recipient
          plan = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: %w(viber)))

          assert_equal "sr", plan.groups.first.locale
        end

        # ---- D8 quiet hours: expressed, not activated ---------------------------

        def test_only_a_routine_group_is_quiet_hours_deferrable
          routine = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: %w(viber)))
          transactional = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell)))

          assert_equal "routine", routine.groups.first.priority
          assert_predicate routine.groups.first, :quiet_hours_deferrable?
          assert_equal "transactional", transactional.groups.first.priority
          refute_predicate transactional.groups.first, :quiet_hours_deferrable?
        end

        # ---- D6 whole-base comparison -------------------------------------------

        def test_the_delivery_set_is_comparable_and_carries_no_recipient
          a = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell push viber whatsapp)))
          b = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell push viber whatsapp)))
          c = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell push viber)))

          assert_equal a.delivery_set, b.delivery_set
          refute_equal a.delivery_set, c.delivery_set
          refute_includes a.delivery_set.to_s, "42"
        end

        def test_the_plan_summary_never_carries_the_recipient_reference
          plan = plan_for(SINGLE_CHANNEL, FakePolicy.new(allow: %w(viber)))

          refute_includes plan.to_h.keys, :recipient_ref
          assert_equal "account#42", plan.recipient_ref
        end

        # ---- the router evaluates; it never acts ---------------------------------

        def test_the_router_asks_the_policy_once_per_candidate_channel_and_does_nothing_else
          policy = FakePolicy.new(allow: %w(viber))
          Router.plan(message_class: SINGLE_CHANNEL, recipient: @recipient, organization: @org,
                      context: {}, mode: :compatibility, policy:, now: @now)

          assert_equal MessageClass::TOPIC_CHANNELS, policy.calls
        end

        def test_the_plan_and_its_groups_are_frozen
          plan = plan_for(THREE_GROUP, FakePolicy.new(allow: %w(bell push viber whatsapp)))

          assert_predicate plan, :frozen?
          assert_predicate plan.groups, :frozen?
          assert(plan.groups.all?(&:frozen?))
          assert(plan.groups.all? { |g| g.channels.frozen? })
          assert_predicate plan.suppressed, :frozen?
        end

        def test_an_unknown_message_class_raises_rather_than_routing_something_made_up
          assert_raises(MessageClass::UnknownMessageClass) do
            plan_for("not.a.real.class", FakePolicy.new(allow: %w(viber)))
          end
        end
      end
    end
  end
end

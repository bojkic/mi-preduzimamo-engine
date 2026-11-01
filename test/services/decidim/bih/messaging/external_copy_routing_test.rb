# frozen_string_literal: true

require "test_helper"
# Only the plan-reading half is exercised here. `decide` needs Modes, Setting
# and a real organization, so it is proved in the Rails harness instead.
require_relative "../../../../../app/services/decidim/bih/messaging/delivery_group"
require_relative "../../../../../app/services/decidim/bih/messaging/routing_plan"
require_relative "../../../../../app/services/decidim/bih/messaging/external_copy_routing"

module Decidim
  module Bih
    module Messaging
      # The adapter's one piece of real arithmetic: turning a frozen plan into
      # the channel list `AccountNotifications` already takes.
      #
      # The rule under test is easy to get wrong in the direction that loses a
      # delivery. The registry models the external copy as a `single` group, so
      # the router pre-selects ONE provider chain out of the permitted
      # candidates and records the rest as `not_selected_single_group`. But
      # `AccountNotifications.preview` applies that same selection again at
      # claim time, over the channels that are reachable THEN. Handing the
      # transport only the router's pre-selection would apply the rule twice:
      # once on stale reachability and once on fresh — and a citizen whose
      # Viber is permitted but unconfigured while a linked session is open
      # would silently stop receiving anything.
      class ExternalCopyRoutingTest < Minitest::Test
        GROUP = ExternalCopyRouting::GROUP

        def group(channels, name: GROUP)
          DeliveryGroup.new(
            name:, channels: Array(channels).map(&:to_s), legs: [], group_mode: "single",
            fanout: "per_recipient", attempt_strategy: :single_request, content_variant: "broadcast",
            content_variant_by_channel: {}, locale: "sr", template: nil, expires_at: nil,
            dedup_identity: "x", dedup_owner: "ledger", timeout_policy: :uncertain_no_retry,
            fallback_owner: "none", terminates_siblings: false, priority: "routine",
            preference_adapter: "community_news_topic", reason_codes: []
          )
        end

        def plan(groups: [], suppressed: [])
          RoutingPlan.new(
            message_class_key: "komsiluk.area_broadcast", recipient_ref: "account#1",
            mode: :compatibility, groups:, suppressed:, policy_version: "p", eligibility_version: "e",
            created_at: nil
          )
        end

        def suppression(channel, reasons, name: GROUP)
          { group: name, channel:, reason_codes: reasons }
        end

        def test_a_channel_the_single_group_rule_deferred_is_still_a_candidate
          subject = plan(groups: [group(%w(viber))],
                         suppressed: [suppression("whatsapp", [:not_selected_single_group])])

          assert_equal %w(viber whatsapp), ExternalCopyRouting.candidates(subject)
        end

        def test_a_channel_a_preference_blocked_is_never_a_candidate
          subject = plan(groups: [group(%w(viber))],
                         suppressed: [suppression("whatsapp", [:preference_blocked]),
                                      suppression("messenger", [:preference_absent])])

          assert_equal %w(viber), ExternalCopyRouting.candidates(subject)
        end

        def test_another_group_s_deferral_is_not_borrowed
          subject = plan(groups: [group(%w(viber))],
                         suppressed: [suppression("push", [:not_selected_single_group], name: "push")])

          assert_equal %w(viber), ExternalCopyRouting.candidates(subject)
        end

        def test_a_plan_without_an_external_copy_group_yields_no_channels
          subject = plan(groups: [group(%w(bell), name: "bell")],
                         suppressed: [suppression("viber", [:preference_absent])])

          assert_empty ExternalCopyRouting.candidates(subject)
        end

        def test_a_deferred_channel_is_never_listed_twice
          subject = plan(groups: [group(%w(viber whatsapp))],
                         suppressed: [suppression("whatsapp", [:not_selected_single_group])])

          assert_equal %w(viber whatsapp), ExternalCopyRouting.candidates(subject)
        end

        def test_the_legacy_decision_routes_nothing_and_names_no_channel
          refute_predicate ExternalCopyRouting::LEGACY, :routed?
          assert_nil ExternalCopyRouting::LEGACY.channels
          assert_nil ExternalCopyRouting::LEGACY.plan
        end
      end
    end
  end
end

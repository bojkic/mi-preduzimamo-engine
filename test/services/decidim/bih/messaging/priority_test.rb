# frozen_string_literal: true

require "test_helper"
# Priority is the one messaging file that legitimately needs ActiveSupport: a
# quiet-hours window is a LOCAL-time rule, and local time in Sarajevo moves
# twice a year. Doing that arithmetic by hand is how a notice arrives an hour
# early on the last Sunday in March.
require "active_support/all"
require_relative "../../../../../app/services/decidim/bih/messaging/priority"

module Decidim
  module Bih
    module Messaging
      # Capacity and deadlines. Every test here is about WHEN and WHERE, never
      # about WHETHER — the last group of tests is the guard that keeps it that
      # way, because a priority that can say "no" is a permission system with a
      # different name.
      class PriorityTest < Minitest::Test
        SARAJEVO = "Europe/Sarajevo"

        # Owner decision D8, verbatim: 21:00-08:00 Europe/Sarajevo, routine only.
        def quiet = { zone: SARAJEVO, from: "21:00", to: "08:00" }

        def group(expires_at: nil, priority: nil)
          Struct.new(:expires_at, :priority).new(expires_at, priority)
        end

        def sarajevo(...) = Time.find_zone!(SARAJEVO).local(...)

        # ---- queues: capacity, taken from the REAL registry vocabulary --------

        def test_authentication_has_a_queue_of_its_own_and_optional_traffic_does_not_share_it
          assert_equal :authentication_critical, Priority.queue_for_priority("authentication")
          refute_equal Priority.queue_for_priority("authentication"), Priority.queue_for_priority("routine")
          refute_equal Priority.queue_for_priority("authentication"), Priority.queue_for_priority("bulk")
          refute_equal Priority.queue_for_priority("authentication"), Priority.queue_for_priority("transactional")
        end

        def test_every_registry_priority_maps_to_a_queue_and_an_unknown_one_falls_back
          # The four words are MessageClass::PRIORITIES. A fifth priority added
          # to the registry without a queue must not silently become nil.
          %w(authentication transactional routine bulk).each do |priority|
            assert_kind_of Symbol, Priority.queue_for_priority(priority)
          end
          assert_equal Priority::DEFAULT_QUEUE, Priority.queue_for_priority("a_priority_nobody_declared")
          assert_equal Priority::DEFAULT_QUEUE, Priority.queue_for_priority(nil)
        end

        def test_queue_for_reads_the_priority_off_a_registry_entry
          entry = Struct.new(:key, :priority).new("phone.verification_code", "authentication")

          assert_equal :authentication_critical, Priority.queue_for(entry)
        end

        # ---- quiet hours: D8, and the DST behaviour it implies ----------------

        def test_no_window_configured_means_send_now
          now = Time.utc(2026, 9, 14, 23, 30)

          assert_equal now, Priority.deliverable_at(group: group(expires_at: now + 3600), now:, window: nil)
          assert_equal now, Priority.deliverable_at(group: group(expires_at: now + 3600), now:, window: {})
        end

        def test_authentication_is_never_delayed_even_inside_the_window
          now = sarajevo(2026, 9, 14, 23, 30).utc

          assert_equal now, Priority.deliverable_at(group: group(expires_at: now + 3600), now:,
                                                    window: quiet, priority: "authentication")
        end

        def test_transactional_is_never_delayed_because_d8_defers_routine_only
          now = sarajevo(2026, 9, 14, 23, 30).utc

          assert_equal now, Priority.deliverable_at(group: group(expires_at: now + 3600), now:,
                                                    window: quiet, priority: "transactional")
          refute Priority.deferrable?("transactional")
          refute Priority.deferrable?("authentication")
          assert Priority.deferrable?("routine")
        end

        # Fail-safe direction for a TIMING control is "send now". A missing or
        # unrecognised priority must never be inferred into a deferral: getting
        # that backwards delays a sign-in code.
        def test_an_absent_or_unknown_priority_is_never_deferred
          now = sarajevo(2026, 9, 14, 23, 30).utc

          assert_equal now, Priority.deliverable_at(group: group(expires_at: now + 3600), now:, window: quiet)
          assert_equal now, Priority.deliverable_at(group: group(expires_at: now + 3600), now:,
                                                    window: quiet, priority: "something_new")
        end

        def test_routine_inside_the_window_is_released_at_the_local_window_end
          now = sarajevo(2026, 9, 14, 23, 30).utc
          expected = sarajevo(2026, 9, 15, 8, 0).utc

          assert_equal expected,
                       Priority.deliverable_at(group: group(expires_at: now + (24 * 3600)), now:,
                                               window: quiet, priority: "routine")
        end

        def test_routine_outside_the_window_is_sent_now
          now = sarajevo(2026, 9, 14, 12, 0).utc

          assert_equal now, Priority.deliverable_at(group: group(expires_at: now + (24 * 3600)), now:,
                                                    window: quiet, priority: "routine")
        end

        # 21:00 is inside the window and 08:00 is the release, so it is outside.
        #
        # Only the START edge is behaviourally observable, and it is asserted
        # precisely: at 21:00:00 the delay must be the full 11 hours. Making the
        # END edge inclusive by mistake changes nothing anyone can see, because a
        # message arriving at exactly 08:00 would then be scheduled for 08:00
        # TOMORROW, 24 hours out, and the starvation bound sends it now anyway.
        # Recorded rather than asserted, so nobody reads this file and believes a
        # guard exists where the bound is doing the work.
        def test_the_window_start_edge_is_inclusive_and_defers_the_full_night
          from_edge = sarajevo(2026, 9, 14, 21, 0).utc
          to_edge = sarajevo(2026, 9, 14, 8, 0).utc

          assert_equal sarajevo(2026, 9, 15, 8, 0).utc,
                       Priority.deliverable_at(group: group(expires_at: from_edge + (24 * 3600)),
                                               now: from_edge, window: quiet, priority: "routine")
          assert_equal to_edge,
                       Priority.deliverable_at(group: group(expires_at: to_edge + (24 * 3600)),
                                               now: to_edge, window: quiet, priority: "routine")
        end

        # 29.03.2026: 02:00 CET -> 03:00 CEST. The night is 10 real hours long.
        def test_spring_forward_releases_at_08_00_local_and_shortens_the_real_delay
          now = sarajevo(2026, 3, 28, 23, 30).utc
          at = Priority.deliverable_at(group: group(expires_at: now + (24 * 3600)), now:,
                                       window: quiet, priority: "routine")

          assert_operator at, :>, now
          assert_equal 8, at.in_time_zone(SARAJEVO).hour
          assert_equal 0, at.in_time_zone(SARAJEVO).min
          # 23:30 -> 08:00 is 8.5 hours on an ordinary night and 7.5 here,
          # because the hour between 02:00 and 03:00 never happens.
          assert_in_delta 7.5 * 3600, at - now, 1
        end

        # 25.10.2026: 03:00 CEST -> 02:00 CET. The night is 12 real hours long,
        # which is exactly why the starvation bound is 12 hours and not 11.
        def test_autumn_back_releases_once_at_08_00_local_over_a_twelve_hour_night
          now = sarajevo(2026, 10, 24, 21, 0).utc
          at = Priority.deliverable_at(group: group(expires_at: now + (24 * 3600)), now:,
                                       window: quiet, priority: "routine")

          assert_equal 8, at.in_time_zone(SARAJEVO).hour
          assert_in_delta 12 * 3600, at - now, 1
          assert_operator at - now, :<=, Priority.starvation_bound.to_i
        end

        # A window whose end falls in the spring-forward GAP has no local time to
        # release at. TZInfo raises PeriodNotFound rather than inventing one.
        def test_a_release_time_that_does_not_exist_locally_moves_forward_instead_of_raising
          window = { zone: SARAJEVO, from: "22:00", to: "02:30" }
          now = sarajevo(2026, 3, 28, 23, 0).utc
          at = Priority.deliverable_at(group: group(expires_at: now + (24 * 3600)), now:,
                                       window:, priority: "routine")

          refute_nil at
          assert_operator at, :>, now
          # 02:30 does not exist on 29.03; the first instant at or after it does.
          assert_equal 3, at.in_time_zone(SARAJEVO).hour
        end

        # The autumn-back hour happens twice. One deterministic answer, always.
        def test_an_ambiguous_release_time_resolves_to_one_deterministic_instant
          window = { zone: SARAJEVO, from: "22:00", to: "02:30" }
          now = sarajevo(2026, 10, 24, 23, 0).utc

          answers = Array.new(3) do
            Priority.deliverable_at(group: group(expires_at: now + (24 * 3600)), now:, window:, priority: "routine")
          end

          assert_equal 1, answers.uniq.size
          assert_equal 2, answers.first.in_time_zone(SARAJEVO).hour
        end

        # Wave A put the D8 hook on the group itself. Priority must ASK it rather
        # than re-derive the rule, or the two copies drift apart silently.
        def test_a_group_that_answers_the_d8_hook_is_believed_over_its_own_priority_field
          now = sarajevo(2026, 9, 14, 23, 30).utc
          hooked = Struct.new(:expires_at, :priority, :quiet_hours_deferrable) do
            def quiet_hours_deferrable? = quiet_hours_deferrable
          end

          deferring = hooked.new(nil, "transactional", true)
          bypassing = hooked.new(nil, "routine", false)

          assert_equal sarajevo(2026, 9, 15, 8, 0).utc,
                       Priority.deliverable_at(group: deferring, now:, window: quiet)
          assert_equal now, Priority.deliverable_at(group: bypassing, now:, window: quiet)
        end

        # …but an explicit caller priority still wins over the hook, so a caller
        # that knows it is sending an authentication message cannot be deferred
        # by a mislabelled group.
        def test_an_explicit_priority_overrides_the_group_hook
          now = sarajevo(2026, 9, 14, 23, 30).utc
          hooked = Struct.new(:expires_at, :priority, :quiet_hours_deferrable) do
            def quiet_hours_deferrable? = quiet_hours_deferrable
          end

          assert_equal now, Priority.deliverable_at(group: hooked.new(nil, "routine", true), now:,
                                                    window: quiet, priority: "authentication")
        end

        # ---- expiry beats holding: a stale notice must never emerge at 08:00 --

        def test_a_notice_that_would_expire_inside_the_window_expires_instead_of_being_held
          now = sarajevo(2026, 9, 14, 23, 30).utc

          assert_nil Priority.deliverable_at(group: group(expires_at: now + 1800), now:,
                                             window: quiet, priority: "routine")
        end

        def test_a_notice_expiring_exactly_at_the_release_is_expired_not_sent
          now = sarajevo(2026, 9, 14, 23, 30).utc
          release = sarajevo(2026, 9, 15, 8, 0).utc

          assert_nil Priority.deliverable_at(group: group(expires_at: release), now:,
                                             window: quiet, priority: "routine")
        end

        def test_a_notice_with_no_deadline_at_all_is_held_rather_than_expired
          now = sarajevo(2026, 9, 14, 23, 30).utc

          assert_equal sarajevo(2026, 9, 15, 8, 0).utc,
                       Priority.deliverable_at(group: group(expires_at: nil), now:, window: quiet, priority: "routine")
        end

        # ---- starvation and fairness -----------------------------------------

        def test_the_starvation_bound_covers_the_longest_possible_d8_night
          assert_operator Priority.starvation_bound, :<=, 12.hours
          assert_operator Priority.starvation_bound, :>=, 12.hours
        end

        def test_a_window_that_would_hold_work_past_the_starvation_bound_sends_now
          window = { zone: SARAJEVO, from: "00:00", to: "23:59" }
          now = sarajevo(2026, 9, 14, 1, 0).utc

          assert_equal now, Priority.deliverable_at(group: group(expires_at: nil), now:, window:, priority: "routine")
        end

        # Backlog fairness: the release order never contradicts the arrival
        # order. Two routine messages that arrive in the same window leave it in
        # the order they arrived, and an earlier one is never released later.
        def test_release_order_never_contradicts_arrival_order
          arrivals = [sarajevo(2026, 9, 14, 21, 1), sarajevo(2026, 9, 14, 23, 30),
                      sarajevo(2026, 9, 15, 3, 0), sarajevo(2026, 9, 15, 7, 59)].map(&:utc)
          releases = arrivals.map do |now|
            Priority.deliverable_at(group: group(expires_at: nil), now:, window: quiet, priority: "routine")
          end

          assert_equal releases, releases.sort
          assert_equal 1, releases.uniq.size, "one window has one release, so the backlog keeps its arrival order"
        end

        # ---- budget: a delay, never a denial ---------------------------------

        def test_an_unconfigured_budget_releases_immediately
          now = Time.utc(2026, 9, 14, 12, 0)

          assert_equal now, Priority.budget_release_at(budget: nil, now:, sent: 10_000)
          assert_equal now, Priority.budget_release_at(budget: {}, now:, sent: 10_000)
        end

        def test_an_exhausted_budget_delays_to_the_end_of_its_period_rather_than_refusing
          now = Time.utc(2026, 9, 14, 12, 30)
          started = Time.utc(2026, 9, 14, 12, 0)
          budget = { max_messages: 100, period_seconds: 3600 }

          assert_equal now, Priority.budget_release_at(budget:, now:, sent: 99, window_started_at: started)
          assert_equal started + 3600,
                       Priority.budget_release_at(budget:, now:, sent: 100, window_started_at: started)
        end

        def test_a_cost_ceiling_is_honoured_the_same_way_as_a_message_count
          now = Time.utc(2026, 9, 14, 12, 30)
          budget = { max_cost: 25.0, period_seconds: 600 }

          assert_equal now, Priority.budget_release_at(budget:, now:, spent: 24.99)
          assert_equal now + 600, Priority.budget_release_at(budget:, now:, spent: 25.0)
        end

        def test_a_budget_delay_flows_through_the_same_expiry_and_starvation_rules
          now = Time.utc(2026, 9, 14, 12, 0)
          release = now + 1800

          assert_equal release, Priority.deliverable_at(group: group(expires_at: now + 3600), now:,
                                                        window: nil, priority: "routine",
                                                        budget_release_at: release)
          assert_nil Priority.deliverable_at(group: group(expires_at: now + 600), now:, window: nil,
                                             priority: "routine", budget_release_at: release)
          assert_equal now, Priority.deliverable_at(group: group(expires_at: nil), now:, window: nil,
                                                    priority: "routine",
                                                    budget_release_at: now + (13 * 3600))
        end

        def test_the_later_of_the_quiet_hours_release_and_the_budget_release_wins
          now = sarajevo(2026, 9, 14, 23, 30).utc
          quiet_release = sarajevo(2026, 9, 15, 8, 0).utc
          later = quiet_release + 900

          assert_equal later, Priority.deliverable_at(group: group(expires_at: nil), now:, window: quiet,
                                                      priority: "routine", budget_release_at: later)
          assert_equal quiet_release,
                       Priority.deliverable_at(group: group(expires_at: nil), now:, window: quiet,
                                               priority: "routine", budget_release_at: now + 60)
        end

        # A budget delay applies to routine work; it must not be able to hold an
        # authentication message, which is the same rule quiet hours obey.
        def test_a_budget_can_never_delay_authentication
          now = Time.utc(2026, 9, 14, 12, 0)

          assert_equal now, Priority.deliverable_at(group: group(expires_at: nil), now:, window: quiet,
                                                    priority: "authentication",
                                                    budget_release_at: now + 3600)
        end

        # Without Rails the host config layer is simply absent, and the answer is
        # "no budget" rather than an exception.
        def test_budget_for_is_empty_and_frozen_when_no_host_config_is_reachable
          budget = Priority.budget_for(organization: nil, message_class: "city.service_alert_viber")

          assert_empty budget
          assert_predicate budget, :frozen?
        end

        # ---- the boundary this whole file exists to hold ---------------------

        # Mutation guard. Adding ANY method that could answer "may this be sent"
        # fails here, which is the point: the file map calls Priority "queue and
        # budget selection (no permission)" and this is what enforces it.
        PUBLIC_API = [
          :budget_for, :budget_release_at, :deferrable?, :deliverable_at,
          :queue_for, :queue_for_priority, :starvation_bound
        ].freeze

        def test_the_public_api_is_capacity_and_deadlines_only
          assert_equal PUBLIC_API.sort, Priority.singleton_methods(false).sort
        end

        def test_priority_answers_no_permission_question
          [:permitted?, :permit?, :allowed?, :allow?, :denied?, :deny?, :eligible?, :send?].each do |forbidden|
            refute_respond_to Priority, forbidden, "Priority must never answer #{forbidden}"
          end
        end

        # nil is EXPIRED, a classified outcome with a reason code — never a
        # silent drop and never a refusal.
        def test_the_only_negative_answer_is_expiry
          now = sarajevo(2026, 9, 14, 23, 30).utc
          answers = [
            Priority.deliverable_at(group: group(expires_at: now + 1800), now:, window: quiet, priority: "routine"),
            Priority.deliverable_at(group: group(expires_at: nil), now:, window: quiet, priority: "routine"),
            Priority.deliverable_at(group: group(expires_at: nil), now:, window: nil, priority: "routine")
          ]

          assert_equal([NilClass, Time, Time], answers.map { |answer| answer.nil? ? NilClass : Time })
          assert(answers.compact.all? { |answer| answer >= now }, "a deadline never points into the past")
        end

        # D8's window is encoded so activation is a host-initializer line rather
        # than a fresh reading of the decision, but it is NOT wired to a default.
        def test_the_d8_window_is_recorded_but_not_activated
          assert_equal({ zone: "Europe/Sarajevo", from: "21:00", to: "08:00" }, Priority::D8_QUIET_HOURS)
          assert_predicate Priority::D8_QUIET_HOURS, :frozen?
        end
      end
    end
  end
end

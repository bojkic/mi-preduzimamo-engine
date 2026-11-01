# frozen_string_literal: true

# Quiet hours are a LOCAL-time rule and local time in Sarajevo moves twice a
# year, so this is the one messaging service that genuinely needs ActiveSupport.
# The requires are explicit and narrow because the pure unit suite loads this
# file with no Rails at all; under Rails they are already satisfied and cost
# nothing.
require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/time/calculations"
require "active_support/core_ext/time/zones"
require "active_support/core_ext/date_and_time/calculations"
require "active_support/values/time_zone"

module Decidim
  module Bih
    module Messaging
      # Queue capacity and deadlines. NOT permission.
      #
      # There is deliberately no `permitted?` here, and nothing in this file may
      # return a send decision. A `Policy::Decision` says whether a message may
      # be sent; this module only says **which queue carries it** and **when it
      # may leave**. The pure suite asserts the whole public surface, so a method
      # that could answer "may this go out" cannot be added without a test
      # failing — that guard is the reason the file exists in this shape.
      #
      # Three rules it encodes, all of them owner decisions or roadmap rules:
      #
      #   1. **Authentication has its own capacity.** `queue_for` puts
      #      authentication work on a queue optional traffic never touches, so a
      #      campaign backlog cannot sit in front of a sign-in code. Reserving
      #      capacity is all it does: it relaxes no throttle and skips no
      #      anti-abuse check — those live in Rack::Attack and in the
      #      verification services, and nothing here can reach them.
      #   2. **Quiet hours defer `routine` work and nothing else (D8).** The
      #      window is 21:00-08:00 Europe/Sarajevo; `critical` (sign-in, phone
      #      verification — the registry spells it `authentication`) and
      #      `important` (the registry spells it `transactional`) bypass
      #      entirely. An absent or unrecognised priority is **never** deferred:
      #      the fail-safe direction for a timing control is "send now", because
      #      the alternative failure is a delayed sign-in code.
      #   3. **A held message expires rather than arriving stale.** When the hold
      #      would outlive the group's own deadline, {deliverable_at} returns
      #      `nil`, which the caller records as `Outcome::EXPIRED` with a reason
      #      code. `nil` is an expiry, never a refusal and never a silent drop.
      #
      # D8's window is recorded here as {D8_QUIET_HOURS} but is **not** wired to
      # a default: `Decidim::Bih.routine_quiet_hours` is `nil` until a host sets
      # it, so on deploy every message is deliverable immediately, exactly as
      # today. Activating it is a host-initializer line plus a Puma and Sidekiq
      # restart, because that accessor is boot-read.
      module Priority
        # `MessageClass::PRIORITIES`, verbatim. Kept as Strings because that is
        # what the registry stores.
        AUTHENTICATION = "authentication"
        TRANSACTIONAL = "transactional"
        ROUTINE = "routine"
        BULK = "bulk"

        # Authentication is the only reservation this makes. Everything else
        # shares `integrations`, which is where all external sending runs today —
        # naming a queue nothing consumes would be a capacity claim with no
        # worker behind it.
        DEFAULT_QUEUE = :integrations
        AUTHENTICATION_QUEUE = :authentication_critical
        QUEUES = {
          AUTHENTICATION => AUTHENTICATION_QUEUE,
          TRANSACTIONAL => DEFAULT_QUEUE,
          ROUTINE => DEFAULT_QUEUE,
          BULK => DEFAULT_QUEUE
        }.freeze

        # D8 says `routine` only. `bulk` is deliberately NOT in this list: every
        # bulk sender on this platform is operator-initiated (`rake
        # decidim_bih:launch:campaign`), so deferring it would silently move an
        # operator's deliberate action to the next morning. If quiet hours should
        # also cover bulk, that is a new owner decision, not an inference.
        DEFERRABLE_PRIORITIES = [ROUTINE].freeze

        # Owner decision D8, recorded so activation is one host line rather than
        # a fresh reading of the decision. Not a default: see the module note.
        D8_QUIET_HOURS = { zone: "Europe/Sarajevo", from: "21:00", to: "08:00" }.freeze

        # The longest a routine message may ever be held. 12 hours is not a round
        # number chosen for comfort: D8's night is 11 hours, and on the last
        # Sunday in October the clocks go back inside it, so 21:00-08:00 is 12
        # REAL hours exactly once a year. A smaller bound would cancel quiet
        # hours on that one night; a larger one would let a pathological window
        # hold work indefinitely.
        STARVATION_BOUND = 12.hours

        EMPTY_BUDGET = {}.freeze

        class << self
          # @param message_class [#priority] a registry Entry, or anything
          #   answering `priority`
          # @return [Symbol] the Sidekiq queue this class's work belongs on
          def queue_for(message_class)
            queue_for_priority(message_class.respond_to?(:priority) ? message_class.priority : nil)
          end

          # @return [Symbol] never nil: an unknown priority falls back to the
          #   shared queue rather than to no queue at all.
          def queue_for_priority(priority)
            QUEUES.fetch(priority.to_s, DEFAULT_QUEUE)
          end

          def starvation_bound
            STARVATION_BOUND
          end

          # Only `routine` defers (D8). Anything else — including nil, including
          # a priority this release has never heard of — is sent now.
          def deferrable?(priority)
            DEFERRABLE_PRIORITIES.include?(priority.to_s)
          end

          # The configured cost/rate budget for one message class.
          #
          # `organization:` is part of the interface and deliberately unused: the
          # per-organization layer is Phase 4's settings work, and taking the
          # argument now means that layer lands without every caller changing.
          # rubocop:disable Lint/UnusedMethodArgument
          def budget_for(organization:, message_class:)
            budgets = host_budgets
            return EMPTY_BUDGET if budgets.empty?

            key = message_class.respond_to?(:key) ? message_class.key.to_s : message_class.to_s
            normalize(budgets[key] || budgets[key.to_sym] || budgets["default"] || budgets[:default])
          end
          # rubocop:enable Lint/UnusedMethodArgument

          # An exhausted budget is a DELAY, never a refusal: it returns the time
          # the period resets, which {deliverable_at} then either schedules or
          # classifies as expired. Nothing here can stop a message on its own.
          def budget_release_at(budget:, now:, sent: 0, spent: 0, window_started_at: nil)
            limits = normalize(budget)
            return now if limits.empty?
            return now unless exhausted?(limits, sent, spent)

            release = (window_started_at || now) + limits[:period_seconds].to_i
            [release, now].max
          end

          # The earliest time this group may be sent, or `nil` when holding it
          # that long would outlive its usefulness — in which case the caller
          # records `Outcome::EXPIRED` with a reason code rather than delivering
          # a stale notice at 08:00.
          #
          # @param group [#expires_at] typically a `DeliveryGroup`
          # @param window [Hash, nil] `{ zone:, from: "HH:MM", to: "HH:MM" }`
          # @param priority [String, Symbol, nil] overrides `group.priority`
          # @param budget_release_at [Time, nil] from {budget_release_at}
          def deliverable_at(group:, now:, window:, priority: nil, budget_release_at: nil)
            return now unless deferrable_group?(group, priority)

            release = [quiet_release(now, window), budget_release_at].compact.max
            return now if release.nil? || release <= now
            # The starvation bound is applied BEFORE the deadline, so work that
            # would be held too long is sent immediately instead of expiring.
            return now if release - now > STARVATION_BOUND

            deadline = group.respond_to?(:expires_at) ? group.expires_at : nil
            return nil if deadline && release >= deadline

            release
          end

          private

          # An explicit `priority:` from the caller wins. Otherwise the GROUP is
          # asked: `DeliveryGroup#quiet_hours_deferrable?` is the hook Wave A
          # built for D8, so it is consulted rather than re-derived here — two
          # copies of the same rule is how they end up disagreeing. A group that
          # answers neither is not deferred, which is the fail-safe direction
          # for a timing control.
          def deferrable_group?(group, priority)
            return deferrable?(priority) if priority
            return group.quiet_hours_deferrable? if group.respond_to?(:quiet_hours_deferrable?)

            group.respond_to?(:priority) ? deferrable?(group.priority) : false
          end

          def exhausted?(limits, sent, spent)
            (limits[:max_messages] && sent.to_i >= limits[:max_messages].to_i) ||
              (limits[:max_cost] && spent.to_f >= limits[:max_cost].to_f)
          end

          # nil when the window is unset, unreadable or `now` is outside it.
          # Unreadable fails to "no quiet hours", which is today's behaviour: a
          # typo in a host initializer must not start holding traffic.
          def quiet_release(now, window)
            return nil if window.nil? || !window.respond_to?(:[]) || (window.respond_to?(:empty?) && window.empty?)

            zone = ActiveSupport::TimeZone[at(window, :zone).to_s]
            from = at(window, :from)
            to = at(window, :to)
            return nil if zone.nil? || from.nil? || to.nil?

            local = now.in_time_zone(zone)
            return nil unless inside?(local, from, to)

            release_local(local, to).utc
          end

          # The start is inclusive and the end is exclusive, so a message that
          # arrives at exactly 08:00 is sent and one that arrives at exactly
          # 21:00 is held. A window that wraps midnight (D8's does) is the
          # `from > to` branch.
          def inside?(local, from, to)
            start_minute = minutes(from)
            end_minute = minutes(to)
            current = (local.hour * 60) + local.min
            return current >= start_minute && current < end_minute if start_minute < end_minute

            current >= start_minute || current < end_minute
          end

          # `change` and `+ 1.day` are both DST-aware on a TimeWithZone: on the
          # spring-forward Sunday a local time inside the gap is moved forward to
          # the first instant that exists (ActiveSupport retries the period
          # lookup an hour later), and on the autumn-back Sunday an ambiguous
          # local time resolves to one deterministic instant. Doing this
          # arithmetic on a UTC Time instead is how a notice arrives an hour
          # early twice a year.
          def release_local(local, to)
            hour, minute = to.to_s.split(":").map(&:to_i)
            candidate = local.change(hour:, min: minute, sec: 0, usec: 0)
            candidate += 1.day if candidate <= local
            candidate
          end

          def minutes(hhmm)
            hour, minute = hhmm.to_s.split(":").map(&:to_i)
            (hour.to_i * 60) + minute.to_i
          end

          def host_budgets
            return {} unless defined?(::Decidim::Bih) && ::Decidim::Bih.respond_to?(:routine_budgets)

            budgets = ::Decidim::Bih.routine_budgets
            budgets.respond_to?(:to_h) ? budgets.to_h : {}
          rescue StandardError
            {}
          end

          def normalize(budget)
            return EMPTY_BUDGET if budget.nil? || !budget.respond_to?(:to_h)

            hash = budget.to_h
            return EMPTY_BUDGET if hash.empty?

            hash.transform_keys(&:to_sym).freeze
          end

          def at(hash, key)
            hash[key] || hash[key.to_s]
          end
        end
      end
    end
  end
end

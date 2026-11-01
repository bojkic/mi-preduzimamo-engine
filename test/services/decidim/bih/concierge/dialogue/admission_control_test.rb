# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "decidim/bih/config"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/turn_budget"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/admission_control"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class AdmissionControlTest < Minitest::Test
          def test_configuration_cannot_raise_the_deployment_wide_limit
            assert_equal 12, AdmissionControl::MAX_LIMIT
            assert_raises(ArgumentError) { AdmissionControl.new(limit: 13) }
            assert_raises(ArgumentError) { AdmissionControl.new(limit: 0) }
          end

          def test_limits_up_to_the_deployment_maximum_are_accepted_and_sent_to_the_store
            [1, 6, 12].each do |limit|
              @redis = FakeRedis.new
              build_control(limit:).with_slot(deadline: budget) { :answer }

              assert_equal limit, acquired_limit, "limit #{limit}"
            end
          end

          def test_default_limit_comes_from_the_environment_clamped_to_the_deployment_maximum
            {
              nil => 2, "6" => 6, "12" => 12, "99" => AdmissionControl::MAX_LIMIT, "0" => 1, "-3" => 1, "many" => 2, "" => 2
            }.each do |value, expected|
              with_admission_limit_env(value) do
                assert_equal expected, Decidim::Bih::Config.admission_limit, value.inspect

                @redis = FakeRedis.new
                AdmissionControl.new(redis: @redis, clock: @clock, token_factory: -> { "lease_token_default_env" }).with_slot(deadline: budget) { :answer }
                assert_equal expected, acquired_limit, value.inspect
              end
            end
          end

          def test_environment_default_never_exceeds_what_the_constructor_accepts
            with_admission_limit_env("1000") do
              assert_equal AdmissionControl::MAX_LIMIT, Decidim::Bih::Config.admission_limit
              AdmissionControl.new(redis: @redis, clock: @clock, token_factory: -> { "lease_token_default_env" })
            end
          end

          class Clock
            attr_accessor :now

            def initialize(now = 100.0) = (@now = now)

            def call = now
          end

          class FakeRedis
            attr_reader :leases, :calls
            attr_accessor :fail_acquire, :fail_release, :acquire_delay, :release_delay

            def initialize
              @leases = Hash.new { |hash, key| hash[key] = {} }
              @calls = []
            end

            def eval(script, keys:, argv:)
              calls << { script:, keys:, argv: }
              return acquire(keys.first, argv) if script.equal?(AdmissionControl::ACQUIRE_SCRIPT)

              release(keys.first, argv.first)
            end

            private

            def acquire(key, argv)
              sleep acquire_delay if acquire_delay
              raise "redis unavailable" if fail_acquire

              now, expires_at, limit, token = argv
              leases[key].delete_if { |_member, expiry| expiry <= now }
              return 0 if leases[key].size >= limit

              leases[key][token] = expires_at
              1
            end

            def release(key, token)
              sleep release_delay if release_delay
              raise "release unavailable" if fail_release

              leases[key].delete(token) ? 1 : 0
            end
          end

          def setup
            @clock = Clock.new
            @redis = FakeRedis.new
            @sequence = 0
            @control = build_control
          end

          def build_control(limit: 2, lease_ttl: 12, redis_timeout: 0.5, max_work_seconds: 10)
            AdmissionControl.new(
              redis: @redis,
              limit:,
              lease_ttl:,
              redis_timeout:,
              max_work_seconds:,
              clock: @clock,
              token_factory: lambda do
                @sequence += 1
                format("lease_token_%04d", @sequence)
              end
            )
          end

          def budget(timeout: 10)
            TurnBudget.new(timeout:, clock: @clock)
          end

          def acquired_limit
            acquire = @redis.calls.find { |call| call[:script].equal?(AdmissionControl::ACQUIRE_SCRIPT) }
            acquire.fetch(:argv).fetch(2)
          end

          def with_admission_limit_env(value)
            previous = ENV.fetch("MILICA_ADMISSION_LIMIT", nil)
            value.nil? ? ENV.delete("MILICA_ADMISSION_LIMIT") : ENV["MILICA_ADMISSION_LIMIT"] = value
            Decidim::Bih::Config.reset!
            yield
          ensure
            previous.nil? ? ENV.delete("MILICA_ADMISSION_LIMIT") : ENV["MILICA_ADMISSION_LIMIT"] = previous
            Decidim::Bih::Config.reset!
          end

          def test_yields_only_when_admitted_and_releases_its_token
            yielded = false
            result = @control.with_slot(deadline: budget) do
              yielded = true
              :answer
            end

            assert yielded
            assert result.admitted?
            assert_equal :answer, result.value
            assert_empty @redis.leases.values.flat_map(&:keys)
          end

          def test_limit_is_shared_across_control_instances
            first = build_control(limit: 1)
            second = build_control(limit: 1)
            inner_yielded = false
            inner = nil

            outer = first.with_slot(deadline: budget) do
              inner = second.with_slot(deadline: budget) { inner_yielded = true }
              :outer
            end

            assert outer.admitted?
            refute inner.admitted?
            assert_equal :capacity, inner.status
            refute inner_yielded
          end

          def test_default_global_limit_never_admits_a_third_active_turn
            controls = 3.times.map { build_control }
            third = nil

            first = controls[0].with_slot(deadline: budget) do
              second = controls[1].with_slot(deadline: budget) do
                third = controls[2].with_slot(deadline: budget) { flunk "third turn must not run" }
                :second
              end
              assert second.admitted?
              :first
            end

            assert first.admitted?
            assert_equal :capacity, third.status
          end

          def test_store_failure_denies_closed_without_yielding
            @redis.fail_acquire = true
            yielded = false

            result = @control.with_slot(deadline: budget) { yielded = true }

            assert_equal :unavailable, result.status
            refute yielded
          end

          def test_expired_budget_does_not_touch_redis_or_yield
            expired = budget(timeout: 1)
            @clock.now = 101.0
            yielded = false

            result = @control.with_slot(deadline: expired) { yielded = true }

            assert_equal :expired, result.status
            refute yielded
            assert_empty @redis.calls
          end

          def test_non_work_timeout_errors_propagate_after_releasing_lease
            [RuntimeError, Timeout::Error].each do |error_class|
              error = assert_raises(error_class) do
                @control.with_slot(deadline: budget) { raise error_class, "provider failed" }
              end

              assert_equal "provider failed", error.message
              assert_empty @redis.leases.values.flat_map(&:keys)
            end
          end

          def test_failed_release_recovers_after_lease_expiry
            @redis.fail_release = true
            result = build_control(limit: 1, lease_ttl: 2).with_slot(deadline: budget) { :first }
            assert result.admitted?
            assert_equal 1, @redis.leases.values.flat_map(&:keys).size

            @redis.fail_release = false
            @clock.now = 102.0
            recovered = build_control(limit: 1, lease_ttl: 2).with_slot(deadline: budget) { :second }

            assert recovered.admitted?
            assert_equal :second, recovered.value
          end

          def test_lease_outlasts_the_allowed_work_budget_for_cleanup
            short = budget(timeout: 1.5)
            @control.with_slot(deadline: short) do
              acquire = @redis.calls.find { |call| call[:script].equal?(AdmissionControl::ACQUIRE_SCRIPT) }
              _now, expires_at = acquire.fetch(:argv)
              assert_in_delta 112.0, expires_at
              assert_operator short.deadline, :<=, expires_at - AdmissionControl::DEFAULT_REDIS_TIMEOUT
            end
          end

          def test_delayed_acquire_is_actually_interrupted_and_denies_closed
            @redis.acquire_delay = 0.2
            control = build_control(redis_timeout: 0.02)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            result = control.with_slot(deadline: budget) { flunk "timed-out acquire must not yield" }

            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            assert_equal :unavailable, result.status
            assert_operator elapsed, :<, 0.15
          end

          def test_delayed_release_is_bounded_and_the_expiring_lease_remains_safe
            @redis.release_delay = 0.2
            control = build_control(limit: 1, lease_ttl: 2, redis_timeout: 0.02)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            result = control.with_slot(deadline: budget) { :answer }

            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            assert result.admitted?
            assert_operator elapsed, :<, 0.15
            assert_equal 1, @redis.leases.values.flat_map(&:keys).size

            @redis.release_delay = nil
            @clock.now = 102.0
            assert build_control(limit: 1, lease_ttl: 2).with_slot(deadline: budget) { :recovered }.admitted?
          end

          def test_slow_admitted_work_is_interrupted_before_its_lease_can_expire
            control = build_control(lease_ttl: 1, redis_timeout: 0.02, max_work_seconds: 0.03)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

            result = control.with_slot(deadline: budget) { sleep 0.2 }

            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            assert_equal :expired, result.status
            assert_operator elapsed, :<, 0.15
            assert_empty @redis.leases.values.flat_map(&:keys)
          end

          def test_work_timeout_caught_by_the_block_cannot_return_an_admitted_late_value
            monotonic = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            control = AdmissionControl.new(
              redis: @redis, lease_ttl: 1, redis_timeout: 0.01, max_work_seconds: 0.02,
              clock: monotonic, token_factory: -> { "lease_token_swallowed" }
            )
            caught = false

            result = control.with_slot(deadline: TurnBudget.new(timeout: 1, clock: monotonic)) do
              sleep 0.1
              :late
            rescue AdmissionControl::WorkTimeout
              caught = true
              :late
            end

            assert caught
            assert_equal :expired, result.status
            assert_nil result.value
            assert_empty @redis.leases.values.flat_map(&:keys)
          end

          def test_post_yield_expiry_uses_exact_max_work_and_lease_child_bounds
            scenarios = [
              [{ max_work_seconds: 2 }, 102.0],
              [{ lease_ttl: 2 }, 101.5]
            ]

            scenarios.each do |configuration, child_deadline|
              @clock.now = 100.0
              before = build_control(**configuration).with_slot(deadline: budget) do
                @clock.now = child_deadline - 0.001
                :before
              end
              assert before.admitted?
              assert_equal :before, before.value

              @clock.now = 100.0
              parent = budget
              exact = build_control(**configuration).with_slot(deadline: parent) do
                @clock.now = child_deadline
                :late
              end
              refute parent.expired?, "the child bound, not the parent deadline, must reject the value"
              assert_equal :expired, exact.status
              assert_nil exact.value
              assert_empty @redis.leases.values.flat_map(&:keys)
            end
          end

          def test_default_redis_client_has_connect_read_and_write_timeouts
            captured = nil
            # The default endpoint comes from the shared resolver, which fails
            # closed under test; stub it so this test never needs REDIS_URL.
            Decidim::Bih::RedisEndpoint.stub(:url, "redis://127.0.0.1:6379/15") do
              Redis.stub(:new, lambda { |**options|
                captured = options
                @redis
              }) do
                AdmissionControl.new(redis_timeout: 0.25).send(:redis)
              end
            end

            assert_equal "redis://127.0.0.1:6379/15", captured.fetch(:url)
            assert_in_delta 0.25, captured.fetch(:connect_timeout)
            assert_in_delta 0.25, captured.fetch(:read_timeout)
            assert_in_delta 0.25, captured.fetch(:write_timeout)
          end

          def test_work_configuration_cannot_exceed_the_global_turn_budget
            assert_raises(ArgumentError) { build_control(max_work_seconds: TurnBudget::MAX_TIMEOUT + 1) }
          end

          def test_malformed_deadline_and_token_fail_closed
            result = @control.with_slot(deadline: 110.0) { flunk "numeric deadlines must not yield" }
            assert_equal :unavailable, result.status

            malformed_child = Object.new
            malformed_child.define_singleton_method(:deadline) { 110.0 }
            malformed_child.define_singleton_method(:remaining_seconds) { 10.0 }
            malformed_child.define_singleton_method(:expired?) { false }
            malformed_child.define_singleton_method(:within) { |_| 10.0 }
            result = @control.with_slot(deadline: malformed_child) { flunk "malformed child budget must not yield" }
            assert_equal :unavailable, result.status
            assert_empty @redis.leases.values.flat_map(&:keys)

            invalid_token = AdmissionControl.new(redis: @redis, clock: @clock, token_factory: -> { "short" })
            result = invalid_token.with_slot(deadline: budget) { flunk "invalid token must not yield" }
            assert_equal :unavailable, result.status
          end
        end
      end
    end
  end
end

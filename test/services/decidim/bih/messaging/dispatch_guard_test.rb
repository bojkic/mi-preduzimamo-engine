# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/dispatch_guard"

module Decidim
  module Bih
    module Messaging
      # The recheck that runs immediately before an irreversible send.
      #
      # It is the SAME function the compose-time readiness banner calls, and
      # that is the point: a preview is an addition, never a replacement. The
      # tests below therefore also pin that the guard has no "already checked"
      # mode anybody could reach for.
      class DispatchGuardTest < Minitest::Test
        def base(**over)
          { authorized: true, governance_current: true, preview_fresh: true,
            preview_matches: true, audience_unchanged: true, expired: false,
            channel_ready: true }.merge(over)
        end

        def call(**over) = DispatchGuard.evaluate(**base(**over))

        def test_all_green_is_allowed
          assert call.allowed?
          assert_empty call.blockers
        end

        def test_an_expired_preview_blocks_even_when_everything_else_is_green
          result = call(preview_fresh: false)
          refute result.allowed?
          assert_includes result.blockers, :preview_expired
        end

        def test_a_stale_preview_digest_blocks
          assert_includes call(preview_matches: false).blockers, :preview_mismatch
        end

        def test_governance_withdrawn_between_preview_and_send_blocks
          assert_includes call(governance_current: false).blockers, :governance_missing
        end

        def test_authorization_revoked_between_preview_and_send_blocks
          assert_includes call(authorized: false).blockers, :not_authorized
        end

        def test_a_changed_audience_blocks_rather_than_sending_the_old_one
          assert_includes call(audience_unchanged: false).blockers, :audience_changed
        end

        def test_an_expired_message_blocks
          assert_includes call(expired: true).blockers, :expired
        end

        def test_an_unready_channel_blocks
          assert_includes call(channel_ready: false).blockers, :channel_not_ready
        end

        # An operator who is told one thing, fixes it and is then told a second
        # thing has been made to guess. Every blocker is reported at once.
        def test_every_blocker_is_reported_not_just_the_first
          result = call(authorized: false, governance_current: false, expired: true)
          assert_equal [:not_authorized, :governance_missing, :expired].sort, result.blockers.sort
        end

        def test_blockers_are_reported_in_a_stable_order
          assert_equal DispatchGuard.evaluate(**base(authorized: false, expired: true)).blockers,
                       DispatchGuard.evaluate(**base(expired: true, authorized: false)).blockers
        end

        # nil is not "fine". A caller that could not establish a fact must be
        # refused, not waved through.
        def test_an_unknown_fact_blocks_rather_than_passing
          DispatchGuard::CHECKS.each_key do |name|
            next if name == :expired

            refute DispatchGuard.evaluate(**base(name => nil)).allowed?,
                   "#{name} = nil must block, not pass"
          end
        end

        def test_an_unknown_expiry_blocks_too
          refute call(expired: nil).allowed?, "not knowing whether it expired is not permission to send"
        end

        # The one rule of this phase, executable: there is no compose-time
        # variant and no way to skip. A preview calls the same evaluate.
        def test_the_guard_has_no_compose_time_mode
          refute DispatchGuard.respond_to?(:evaluate_at_compose_time)
          refute DispatchGuard.respond_to?(:skip)
          refute DispatchGuard.respond_to?(:bypass)
          refute DispatchGuard::Result.instance_methods.include?(:allowed=)
        end

        # Messaging services must not reach into the governance, operator-audit
        # or feedback ledgers; those are independent records with their own
        # retention and access rules. Each surface resolves its own approval and
        # passes the boolean in.
        def test_the_guard_reaches_into_no_other_ledger
          source = File.read(File.expand_path("../../../../../app/services/decidim/bih/messaging/dispatch_guard.rb", __dir__))
          code = source.lines.reject { |line| line.strip.start_with?("#") }.join
          refute_match(/OperatorAuditEvent|GovernanceApproval|ConciergeFeedback/, code)
        end

        def test_a_result_is_frozen_so_a_caller_cannot_talk_itself_into_a_send
          assert call.frozen?
          assert call.blockers.frozen?
        end

        # Aggregate-safe: what a log or an artifact may carry.
        def test_to_h_carries_blockers_and_no_identifier
          result = call(authorized: false)
          assert_equal({ allowed: false, blockers: [:not_authorized] }, result.to_h)
        end

        # Every declared check must be able to block something. A check nobody
        # can fail is decoration that reads as a protection.
        def test_every_declared_check_can_produce_its_blocker
          DispatchGuard::CHECKS.each do |name, blocker|
            failing = name == :expired
            assert_includes call(name => failing).blockers, blocker,
                            "#{name} never produces #{blocker}"
          end
        end
      end
    end
  end
end

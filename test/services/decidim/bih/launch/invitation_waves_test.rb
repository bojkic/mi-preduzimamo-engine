# frozen_string_literal: true

require "test_helper"
require "active_support/time"
require "decidim/bih"
require_relative "../../../../../app/services/decidim/bih/launch/invitation_waves"

module Decidim
  module Bih
    module Launch
      class InvitationWavesTest < Minitest::Test
        SINGLE = [{ "starts_on" => "2026-09-06", "quantity" => 310 }].freeze
        THREE = [
          { "starts_on" => "2026-09-06", "quantity" => 150 },
          { "starts_on" => "2026-09-11", "quantity" => 150 },
          { "starts_on" => "2026-09-15", "quantity" => 150 }
        ].freeze

        def setup
          @original = Decidim::Bih.launch_invitation_waves
          Decidim::Bih.launch_invitation_waves = SINGLE
        end

        def teardown
          Decidim::Bih.launch_invitation_waves = @original
        end

        # The fast suite never boots a Rails app, so Time.zone has no default
        # (config.time_zone is never applied). Time.use_zone scopes a zone for
        # Time.zone.parse below without leaking into other test files sharing
        # this process — the same pattern earning_rules_test.rb and
        # streaks_weekly_test.rb use. Europe/Sarajevo matches
        # InvitationWaves::TIME_ZONE so the wall-clock "now:" strings above
        # (e.g. "2026-09-05 23:59:59") land on the calendar date they read as.
        def waves(issued: 0, now: "2026-09-10 12:00:00")
          Time.use_zone("Europe/Sarajevo") do
            InvitationWaves.new(organization: nil, now: Time.zone.parse(now), issued_count: issued)
          end
        end

        def test_single_wave_totals_three_hundred_and_ten
          assert_equal 310, waves.total
        end

        def test_remaining_counts_down_from_the_total
          assert_equal 310, waves.remaining
          assert_equal 10, waves(issued: 300).remaining
        end

        def test_remaining_never_goes_negative
          assert_equal 0, waves(issued: 999).remaining
        end

        def test_state_is_not_started_before_the_first_wave_opens
          assert_equal :not_started, waves(now: "2026-09-05 23:59:59").state
        end

        def test_state_is_open_while_invitations_remain
          assert_equal :open, waves(issued: 5).state
        end

        def test_state_is_all_issued_when_the_last_wave_is_spent
          assert_equal :all_issued, waves(issued: 310).state
        end

        # The service still supports waves even though the client chose one —
        # restoring them must be a config change, never a code change.
        def test_three_wave_configuration_reports_an_exhausted_wave_and_the_next_one
          Decidim::Bih.launch_invitation_waves = THREE
          subject = waves(issued: 150, now: "2026-09-08 12:00:00")

          assert_equal :wave_exhausted, subject.state
          assert_equal Date.new(2026, 9, 11), subject.next_wave[:starts_on]
          assert_equal 450, subject.total
        end

        def test_three_wave_configuration_only_counts_waves_that_have_opened
          Decidim::Bih.launch_invitation_waves = THREE
          subject = waves(issued: 0, now: "2026-09-08 12:00:00")

          assert_equal 150, subject.available_so_far, "only the first wave has opened"
          assert_equal 150, subject.remaining
        end

        # An explicit issued_count: (as every test above passes) is knowledge,
        # not a failed read — never degraded.
        def test_not_degraded_when_issued_count_is_given_explicitly
          refute waves(issued: 0).degraded?
          refute waves(issued: 300).degraded?
        end

        # organization: nil short-circuits count_issued to a legitimate 0
        # ("no reward exists yet") rather than hitting the rescue — also never
        # degraded. Bypasses the `waves` helper's issued_count: to exercise the
        # count_issued codepath itself.
        def test_not_degraded_when_organization_is_nil_and_issued_is_computed
          subject = Time.use_zone("Europe/Sarajevo") do
            InvitationWaves.new(organization: nil, now: Time.zone.parse("2026-09-10 12:00:00"))
          end

          assert_equal 0, subject.issued
          refute subject.degraded?
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/message_class"
require_relative "../../../../../app/services/decidim/bih/messaging/modes"
require_relative "../../../../../app/services/decidim/bih/messaging/enrollment"

module Decidim
  module Bih
    module Messaging
      # Task 2.0. Enrollment is a thin reader over the Phase 1 mode store, and
      # these examples are also the tripwire that catches Phase 1 moving under
      # Phase 2: if `Modes` gains a fourth mode or renames `dispatch_disabled?`,
      # the first two tests fail loudly instead of Phase 2 quietly routing under
      # an assumption nobody re-checked.
      class EnrollmentTest < Minitest::Test
        FakeOrg = Struct.new(:id)

        # An enrolled registry key and an unenrolled one, read from the real
        # registry rather than invented, so the examples cannot drift from it.
        ENROLLED = "city.service_alert_viber"
        UNENROLLED = "postal.verification_letter"

        # Records what was asked of the store. Used only where the real `Modes`
        # cannot run without Rails (the host-config layer) or must not run at
        # all (the nil-organization guard).
        class RecordingModes
          attr_reader :calls

          def initialize(modes: {}, disabled: [])
            @modes = modes
            @disabled = disabled
            @calls = []
          end

          def for(message_class)
            @calls << [:for, message_class]
            @modes.fetch(message_class, Modes::LEGACY)
          end

          def dispatch_disabled?(message_class)
            @calls << [:dispatch_disabled?, message_class]
            @disabled.include?(message_class)
          end
        end

        class BrokenModes
          def for(_message_class) = raise("store unavailable")

          def dispatch_disabled?(_message_class) = raise("store unavailable")
        end

        def setup
          @org = FakeOrg.new(7)
        end

        def modes_with(settings)
          Modes.new(organization: @org, settings: settings)
        end

        # ---- the Phase 1 contract this task binds to -------------------------

        def test_the_phase_1_mode_store_is_present_and_has_the_shape_phase_2_assumes
          assert_includes Modes.public_instance_methods, :for
          assert_includes Modes.public_instance_methods, :dispatch_disabled?
          assert_equal %w(legacy compatibility target), Modes::ALL
          assert_equal "legacy", Modes::DEFAULT
          assert_equal "messaging", Modes::NAMESPACE
        end

        def test_enrollment_modes_mirror_the_store_rather_than_inventing_a_fourth
          assert_equal Modes::ALL, Enrollment::MODES.map(&:to_s)
          refute_includes Enrollment::MODES, :shadow
        end

        # ---- mode ------------------------------------------------------------

        # The real `Modes` falls through to the host-config layer when no
        # per-organization row exists, and that layer needs Rails. The double
        # stands in for exactly that one hop; the harness proves the real read.
        def test_an_enrolled_class_with_nothing_stored_is_legacy
          assert_equal :legacy, Enrollment.mode(organization: @org, message_class: ENROLLED,
                                                modes: RecordingModes.new)
        end

        def test_each_recognised_mode_round_trips_through_the_real_store
          Modes::ALL.each do |value|
            modes = modes_with("mode.#{ENROLLED}" => value)
            assert_equal value.to_sym, Enrollment.mode(organization: @org, message_class: ENROLLED, modes:)
          end
        end

        def test_phase_1_normalises_an_unrecognised_stored_value_to_legacy
          modes = modes_with("mode.#{ENROLLED}" => "targett")
          assert_equal :legacy, Enrollment.mode(organization: @org, message_class: ENROLLED, modes:)
        end

        # Defence in depth, and deliberately NOT a duplicate of the test above:
        # that one proves `Modes` normalises, this one proves Enrollment does
        # too. Without it, Enrollment's own guard is dead code that only a
        # future store change would expose — in production, as a live `target`.
        def test_an_unrecognised_value_reaching_this_reader_is_normalised_here_too
          %w(targett shadow TARGET).each do |raw|
            recorder = RecordingModes.new(modes: { ENROLLED => raw })
            assert_equal :legacy, Enrollment.mode(organization: @org, message_class: ENROLLED, modes: recorder),
                         "#{raw.inspect} must not be read as a runtime mode"
          end
        end

        def test_phase_1_normalises_shadow_because_it_is_a_registry_state_not_a_mode
          modes = modes_with("mode.#{ENROLLED}" => "shadow")
          assert_equal :legacy, Enrollment.mode(organization: @org, message_class: ENROLLED, modes:)
        end

        def test_a_class_the_registry_has_not_enrolled_can_never_be_flagged_off_legacy
          modes = modes_with("mode.#{UNENROLLED}" => "target")
          assert_equal :legacy, Enrollment.mode(organization: @org, message_class: UNENROLLED, modes:)
        end

        def test_nil_organization_is_legacy_and_reads_nothing
          recorder = RecordingModes.new(modes: { ENROLLED => "target" })
          assert_equal :legacy, Enrollment.mode(organization: nil, message_class: ENROLLED, modes: recorder)
          refute Enrollment.dispatch_enabled?(organization: nil, message_class: ENROLLED, modes: recorder)
          assert_empty recorder.calls
        end

        def test_a_blank_message_class_is_legacy_and_reads_nothing
          recorder = RecordingModes.new
          assert_equal :legacy, Enrollment.mode(organization: @org, message_class: "  ", modes: recorder)
          assert_equal :legacy, Enrollment.mode(organization: @org, message_class: nil, modes: recorder)
          assert_empty recorder.calls
        end

        # ---- dispatch kill switch -------------------------------------------

        def test_dispatch_is_enabled_when_nothing_is_stored
          assert Enrollment.dispatch_enabled?(organization: @org, message_class: ENROLLED, modes: modes_with({}))
        end

        def test_dispatch_disable_is_independent_of_mode
          modes = modes_with("mode.#{ENROLLED}" => "target", "dispatch_disabled.#{ENROLLED}" => "true")
          assert_equal :target, Enrollment.mode(organization: @org, message_class: ENROLLED, modes:)
          refute Enrollment.dispatch_enabled?(organization: @org, message_class: ENROLLED, modes:)
        end

        def test_the_default_disable_key_covers_every_class
          modes = modes_with("dispatch_disabled.default" => "1")
          refute Enrollment.dispatch_enabled?(organization: @org, message_class: ENROLLED, modes:)
          refute Enrollment.dispatch_enabled?(organization: @org, message_class: UNENROLLED, modes:)
        end

        # ---- failure direction ----------------------------------------------

        def test_a_store_error_fails_closed_to_legacy_and_disabled_dispatch
          broken = BrokenModes.new
          assert_equal :legacy, Enrollment.mode(organization: @org, message_class: ENROLLED, modes: broken)
          refute Enrollment.dispatch_enabled?(organization: @org, message_class: ENROLLED, modes: broken)
          refute Enrollment.routes?(organization: @org, message_class: ENROLLED, modes: broken)
        end

        # ---- the composite question every enrolled sender asks ---------------

        def test_routes_requires_both_a_non_legacy_mode_and_enabled_dispatch
          refute Enrollment.routes?(organization: @org, message_class: ENROLLED,
                                    modes: RecordingModes.new)
          assert Enrollment.routes?(organization: @org, message_class: ENROLLED,
                                    modes: RecordingModes.new(modes: { ENROLLED => "compatibility" }))
          refute Enrollment.routes?(organization: @org, message_class: ENROLLED,
                                    modes: RecordingModes.new(modes: { ENROLLED => "compatibility" },
                                                              disabled: [ENROLLED]))
        end

        def test_routes_asks_one_snapshot_both_questions
          recorder = RecordingModes.new(modes: { ENROLLED => "target" })
          Enrollment.routes?(organization: @org, message_class: ENROLLED, modes: recorder)
          assert_equal [[:for, ENROLLED], [:dispatch_disabled?, ENROLLED]], recorder.calls
        end

        # ---- registry enrollment vs runtime mode -----------------------------

        def test_enrolled_reports_the_registry_state_not_the_flag
          assert Enrollment.enrolled?(ENROLLED)
          refute Enrollment.enrolled?(UNENROLLED)
          refute Enrollment.enrolled?("not.a.real.class")
        end

        def test_shadow_observed_is_registry_enrolled_but_still_running_legacy
          assert Enrollment.shadow_observed?(organization: @org, message_class: ENROLLED,
                                             modes: RecordingModes.new)
          refute Enrollment.shadow_observed?(organization: @org, message_class: ENROLLED,
                                             modes: RecordingModes.new(modes: { ENROLLED => "compatibility" }))
          refute Enrollment.shadow_observed?(organization: @org, message_class: UNENROLLED,
                                             modes: RecordingModes.new)
        end

        # ---- recorded latency -------------------------------------------------

        def test_refresh_latency_is_zero_because_the_setting_layer_is_a_per_job_snapshot
          assert_equal 0, Enrollment.refresh_latency_seconds
          assert Enrollment.host_config_requires_restart?
        end
      end
    end
  end
end

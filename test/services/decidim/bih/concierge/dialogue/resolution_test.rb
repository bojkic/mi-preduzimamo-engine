# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/resolution"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ResolutionTest < Minitest::Test
          ENGINE_ROOT = File.expand_path("../../../../../../", __dir__)
          RECORDER = File.join(ENGINE_ROOT, "app/services/decidim/bih/concierge/usage_aggregate_recorder.rb")
          RUNNER = File.join(ENGINE_ROOT, "app/services/decidim/bih/concierge/dialogue/procedure_runner.rb")
          CONTROLLER = File.join(ENGINE_ROOT, "app/controllers/decidim/bih/concierge/web_chat_controller.rb")

          # One vocabulary. The recorder cannot be loaded here (it needs Rails),
          # so its list is read from source rather than duplicated by hand.
          def test_the_vocabulary_matches_the_usage_recorder
            source = File.read(RECORDER)[/RESOLUTIONS = %w\(\s*(.*?)\s*\)\.freeze/m, 1]

            refute_nil source, "UsageAggregateRecorder::RESOLUTIONS not found — the vocabulary contract needs updating"
            assert_equal source.split, Resolution::VALUES
          end

          def test_every_resolution_the_dialogue_finishes_with_is_in_the_vocabulary
            %w(procedure_runner.rb coordinator.rb).each do |name|
              path = File.join(ENGINE_ROOT, "app/services/decidim/bih/concierge/dialogue", name)
              File.read(path).scan(/resolution: "([a-z_]+)"/).flatten.uniq.each do |resolution|
                assert Resolution.valid?(resolution), "#{name} finishes with an unknown resolution #{resolution.inspect}"
              end
            end
          end

          def test_only_a_clarification_keeps_the_task_open
            assert_equal %w(clarification), (Resolution::VALUES.reject { |value| Resolution.settles_task?(value) })
            assert_equal %w(clarification), (Resolution::VALUES.reject { |value| Resolution.offers_resume?(value) })
          end

          # The hand-off offered AT the clarification limit is the one exception.
          def test_only_a_handoff_at_the_clarification_limit_keeps_the_pending_slot
            assert Resolution.retains_pending_slot?(Resolution::HANDOFF, clarification_count: 2)
            refute Resolution.retains_pending_slot?(Resolution::HANDOFF, clarification_count: 1)
            refute Resolution.retains_pending_slot?(Resolution::ANSWERED, clarification_count: 2)
            assert Resolution.retains_clarification_count?(Resolution::HANDOFF)
            refute Resolution.retains_clarification_count?(Resolution::ANSWERED)
          end

          # ---------------------------------------------------------------
          # The honest-outcome rule (Task 9b)
          # ---------------------------------------------------------------

          # The defect: a reply that says "I have no verified data for this"
          # was counted as an answered turn.
          def test_an_available_read_with_no_facts_is_not_an_answer
            refute_equal Resolution::ANSWERED, Resolution.empty_available_read(stale: false)
            assert_equal Resolution::UNSUPPORTED, Resolution.empty_available_read(stale: false)
            assert Resolution.unresolved?(Resolution.empty_available_read(stale: false))
          end

          # Stale is a statement about the SOURCE, not about our coverage, and
          # keeps its own label so the retry advice and the operator's work
          # stay different.
          def test_a_stale_read_with_no_facts_stays_a_source_health_label
            resolution = Resolution.empty_available_read(stale: true)

            assert_equal Resolution::SOURCE_UNAVAILABLE, resolution
            assert Resolution.source_health?(resolution)
            refute Resolution.source_health?(Resolution.empty_available_read(stale: false))
          end

          # "We checked and there genuinely are none" is a real answer and must
          # not be reclassified as a failure.
          def test_a_complete_zero_result_read_is_still_an_answer
            assert_equal Resolution::ANSWERED, Resolution.empty_read(complete: true)
            assert Resolution.succeeded?(Resolution.empty_read(complete: true))
          end

          def test_an_empty_read_without_a_complete_answer_is_unresolved
            assert_equal Resolution::UNSUPPORTED, Resolution.empty_read(complete: false)
            assert Resolution.unresolved?(Resolution.empty_read(complete: false))
            refute Resolution.succeeded?(Resolution.empty_read(complete: false))
          end

          # The two empty branches must not collapse into one label: an
          # unreviewed/unavailable source, a stale source and a complete empty
          # answer share a visual shape in the chat and mean different things.
          def test_the_empty_branches_stay_distinguishable
            labels = [
              Resolution.empty_read(complete: true),
              Resolution.empty_read(complete: false),
              Resolution.empty_available_read(stale: true)
            ]

            assert_equal labels.uniq, labels, "the empty branches collapsed onto one resolution"
          end

          # Both call sites must ask this module. A hardcoded "answered" beside
          # a refusal is exactly the defect Task 9b removed.
          def test_both_unresolved_empty_branches_delegate_the_label
            source = File.read(RUNNER)

            assert_match(/def render_empty_available_read.*?Resolution\.empty_available_read/m, source)
            assert_match(/when "empty".*?Resolution\.empty_read\(complete:/m, source)
          end

          # ---------------------------------------------------------------
          # Three separate things
          # ---------------------------------------------------------------

          def test_success_and_unresolved_partition_the_vocabulary
            assert_equal [], (Resolution::SUCCEEDED & Resolution::UNRESOLVED)
            assert_equal Resolution::VALUES.sort, (Resolution::SUCCEEDED + Resolution::UNRESOLVED).sort
          end

          # The historical aggregate bucket must keep meaning what it meant, or
          # rows before and after this change stop being comparable.
          def test_the_legacy_success_bucket_membership_is_unchanged
            assert_equal %w(answered handoff draft submitted clarification cancelled).sort, Resolution::SUCCEEDED.sort
          end

          def test_the_controller_reads_the_bucket_from_here
            assert_match(/SUCCESS_RESOLUTIONS = Dialogue::Resolution::SUCCEEDED/, File.read(CONTROLLER))
          end

          # Source health is about a dependency. It is never evidence that a
          # question was answered, and never a citizen rating.
          def test_source_health_is_not_a_statement_about_the_answer
            Resolution::SOURCE_HEALTH.each do |resolution|
              refute Resolution.succeeded?(resolution), "#{resolution} must not count as an answered turn"
            end
            assert_equal %w(source_unavailable provider_unavailable), Resolution::SOURCE_HEALTH
          end

          # Safety guidance names an emergency number. Milica contacted nobody
          # and resolved nothing, so its label must never say otherwise.
          def test_safety_guidance_has_a_distinct_unresolved_non_dispatch_label
            assert_equal "safety_guidance", Resolution::SAFETY_GUIDANCE
            assert Resolution.valid?(Resolution::SAFETY_GUIDANCE)
            assert Resolution.unresolved?(Resolution::SAFETY_GUIDANCE)
            refute Resolution.succeeded?(Resolution::SAFETY_GUIDANCE)
            refute Resolution.source_health?(Resolution::SAFETY_GUIDANCE)
          end

          def test_an_unknown_label_is_not_valid
            refute Resolution.valid?("ok")
            refute Resolution.valid?(nil)
            assert Resolution.valid?("answered")
          end
        end
      end
    end
  end
end

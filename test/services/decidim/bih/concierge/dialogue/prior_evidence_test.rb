# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/exclude"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/prior_evidence"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class PriorEvidenceTest < Minitest::Test
          NOW = Time.utc(2026, 9, 7, 12)
          # Stored evidence stays ISO 8601; replies render it for humans in
          # Europe/Sarajevo, where NOW is 7.9.2026 at 14:00.
          HUMAN = {
            "2026-08-31T12:00:00Z" => "31.8.2026. u 14:00", NOW.iso8601 => "danas u 14:00",
            "2026-09-14T12:00:00Z" => "14.9.2026. u 14:00", "2026-09-08T08:00:00Z" => "8.9.2026. u 10:00", "2026-09-06" => "juče"
          }.freeze

          def result(status: "ok", coverage: { "area_slugs" => ["dvorovi"] }, validity: {})
            Contracts::ReadResult.new(status:, coverage:, validity:, checked_at: NOW)
          end

          def fact(**extra)
            { "id" => "notice:1", "source_id" => "water_operator", "source_label" => "Water operator",
              "observed_at" => "2026-09-06", "starts_at" => "2026-09-08T08:00:00Z" }.merge(extra)
          end

          def test_captures_only_supported_public_facts_with_individual_times
            evidence = PriorEvidence.capture(
              result: result, facts: [fact("checked_at" => NOW.iso8601)], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )

            assert_equal "public_read", evidence.fetch("kind")
            assert_equal "2026-09-06", evidence.dig("facts", 0, "observed_at")
            assert_equal "2026-09-08T08:00:00Z", evidence.dig("facts", 0, "starts_at")
            assert_equal NOW.iso8601, evidence.dig("facts", 0, "checked_at")
            assert_equal ["dvorovi"], evidence.dig("scope", "area_slugs")

            without_fact_check = PriorEvidence.capture(
              result:, facts: [fact], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )
            assert_nil without_fact_check.dig("facts", 0, "checked_at")
          end

          def test_rejects_private_and_unsupported_capture
            assert_nil PriorEvidence.capture(result: result, facts: [fact], action: "report_status", topic: "report", now: NOW, expires_at: NOW.to_f + 60)
            assert_nil PriorEvidence.capture(result: result, facts: [fact], action: "ask_information", topic: "account", now: NOW, expires_at: NOW.to_f + 60)
            captured = PriorEvidence.capture(
              result:, facts: [fact(source_url: "https://example.test")], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )
            refute captured.dig("facts", 0).has_key?("source_url")
            assert_nil PriorEvidence.capture(
              result:, facts: [fact("source_label" => "kod je 123456")], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )
            assert_nil PriorEvidence.capture(
              result:, facts: [fact("source_label" => "https://operator.example/notice")], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )
            assert_nil PriorEvidence.capture(
              result:, facts: [fact.except("source_id")], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )
            assert_nil PriorEvidence.capture(
              result: result(coverage: { "area_slugs" => "dvorovi" }), facts: [fact], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )
          end

          def test_accepts_future_applicability_but_not_future_observation
            metadata = PriorEvidence.capture(
              result: result(validity: { "service_day" => "2027-01-01", "ends_at" => "2027-01-02T00:00:00Z" }),
              facts: [fact("valid_until" => "2027-01-03")], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )
            assert_equal "2027-01-01", metadata.dig("scope", "service_day")
            assert_nil PriorEvidence.capture(
              result:, facts: [fact("observed_at" => "2027-01-01")], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )
            assert_nil PriorEvidence.capture(
              result:, facts: [fact("starts_at" => "2026-02-30T08:00:00Z")], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )
          end

          def test_no_uri_scheme_is_retained_as_a_source_label
            %w(ftp://example.test/file mailto:fixture@example.test tel:+387000000 data:text/plain,fixture javascript:alert).each do |label|
              assert_nil PriorEvidence.capture(
                result:, facts: [fact("source_label" => label)], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
              )
            end
            assert PriorEvidence.capture(
              result:, facts: [fact("source_label" => "Izvor: Vodovod")], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60
            )
          end

          def test_normalization_rejects_unbounded_private_fields_and_expires_without_sliding
            metadata = PriorEvidence.capture(result: result, facts: [fact], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60).dup
            metadata["query"] = "private citizen text"
            assert_raises(Contracts::Invalid) { PriorEvidence.normalize(metadata, now: NOW, state_expires_at: NOW.to_f + 60) }

            valid = PriorEvidence.capture(result: result, facts: [fact], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60)
            assert_nil PriorEvidence.normalize(valid, now: NOW + 61, state_expires_at: NOW.to_f + 120)
          end

          def test_normalization_rejects_malformed_nested_metadata_without_key_errors
            metadata = PriorEvidence.capture(result: result, facts: [fact], action: "ask_information", topic: "water", now: NOW, expires_at: NOW.to_f + 60)
            invalid_fact = Marshal.load(Marshal.dump(metadata))
            invalid_fact.fetch("facts").first.delete("id")
            assert_raises(Contracts::Invalid) { PriorEvidence.normalize(invalid_fact, now: NOW, state_expires_at: NOW.to_f + 60) }

            invalid_scope = Marshal.load(Marshal.dump(metadata))
            invalid_scope.fetch("scope")["area_slugs"] = "dvorovi"
            assert_raises(Contracts::Invalid) { PriorEvidence.normalize(invalid_scope, now: NOW, state_expires_at: NOW.to_f + 60) }

            duplicate_scope = Marshal.load(Marshal.dump(metadata))
            duplicate_scope.fetch("scope")["area_slugs"] = %w(dvorovi dvorovi)
            assert_raises(Contracts::Invalid) { PriorEvidence.normalize(duplicate_scope, now: NOW, state_expires_at: NOW.to_f + 60) }

            string_expiry = Marshal.load(Marshal.dump(metadata))
            string_expiry["expires_at"] = (NOW.to_f + 60).to_s
            assert_raises(Contracts::Invalid) { PriorEvidence.normalize(string_expiry, now: NOW, state_expires_at: NOW.to_f + 60) }
          end

          def test_public_neighborhood_capture_requires_explicit_scope_and_remains_metadata_only
            PriorEvidence::PUBLIC_NEIGHBORHOOD_SCOPES.each do |scope|
              evidence = capture_neighborhood(result(coverage: { "scope" => scope, "area_slugs" => ["dvorovi"] }), facts: [
                fact("text" => "Public notice prose", "source_text" => { "title" => "Original source prose" },
                     "source_url" => "https://operator.example/notice", "checked_at" => NOW.iso8601)
              ])
              assert_equal "public_read", evidence.fetch("kind")
              assert_equal ["dvorovi"], evidence.dig("scope", "area_slugs")
              assert_equal NOW.iso8601, evidence.dig("facts", 0, "checked_at")
              assert_equal %w(id source_id source_label observed_at starts_at checked_at).sort, evidence.fetch("facts").first.keys.sort
              %w(Public Original https source_text).each { |text| refute_includes JSON.generate(evidence), text }
            end

            [nil, "", "unknown", "area_public_reports_extra"].each do |scope|
              assert_nil capture_neighborhood(result(coverage: { "scope" => scope, "area_slugs" => ["dvorovi"] }))
            end
            assert_nil capture_neighborhood(result(coverage: nil))
            PriorEvidence::PUBLIC_NEIGHBORHOOD_SCOPES.each do |scope|
              assert_nil capture_neighborhood(result(coverage: { "scope" => scope, "visibility" => "member_board", "area_slugs" => ["dvorovi"] }))
            end
          end

          def test_public_neighborhood_keeps_fact_size_count_and_expiry_bounds
            read = result(coverage: { "scope" => "area_public_reports", "area_slugs" => ["dvorovi"] })
            facts = 8.times.map { |index| fact("id" => "notice:#{index}") }
            evidence = capture_neighborhood(read, facts:)
            assert_equal 8, evidence.fetch("facts").length
            assert_equal 4096, PriorEvidence::MAX_BYTES
            assert_operator JSON.generate(evidence).bytesize, :<=, PriorEvidence::MAX_BYTES
            assert_nil capture_neighborhood(read, facts: facts + [fact("id" => "notice:9")])
            oversized = 8.times.map { |index| fact("id" => "notice:#{index}:#{"x" * 140}", "source_id" => "s" * 160, "source_label" => "S" * 160) }
            assert_nil capture_neighborhood(read, facts: oversized)
            assert_equal NOW.to_f + 60, evidence.fetch("expires_at")
            assert_nil PriorEvidence.normalize(evidence, now: NOW + 61, state_expires_at: NOW.to_f + 600)
            assert_raises(Contracts::Invalid) { PriorEvidence.normalize(evidence, now: NOW, state_expires_at: NOW.to_f + 59) }
          end

          def test_single_family_neighborhood_dates_use_component_not_notice_window
            windows = {
              "area_public_reports" => ["reports", { "starts_at" => "2026-08-31T12:00:00Z", "ends_at" => NOW.iso8601 }],
              "public_neighborhood_activities" => ["activities", { "starts_at" => NOW.iso8601, "ends_at" => "2026-09-14T12:00:00Z" }]
            }
            with_renderer do |runner, context, state, reads|
              windows.each do |scope, (component, window)|
                coverage = { "scope" => scope, "area_slugs" => ["dvorovi"], "starts_at" => NOW.iso8601,
                             "ends_at" => "2026-09-08T00:00:00Z", component => window }
                evidence = capture_neighborhood(result(coverage:, validity: { "service_day" => "2026-09-07", "ends_at" => "2026-09-08T00:00:00Z" }))
                assert_equal({ "area_slugs" => ["dvorovi"] }.merge(window), evidence.fetch("scope"))
                state.merge!("active_task" => "ask_information", "topic" => "neighborhood", "prior_evidence" => evidence)
                date = runner.prior_evidence_follow_up(kind: "date", state:, context:, message: "Za koji datum važi?")
                expected_window = window.values.map { |value| HUMAN.fetch(value) }.join("; ")
                assert_equal I18n.t("decidim.bih.dialogue.prior_evidence_requested_window", locale: :sr, time: expected_window),
                             date.reply.text.lines.first.chomp
              end
              assert_empty reads
            end
          end

          def test_mixed_neighborhood_has_no_universal_date_unless_complete_component_windows_match
            notice_window = { "starts_at" => NOW.iso8601, "ends_at" => "2026-09-08T00:00:00Z" }
            coverage = { "scope" => "collected_public_neighborhood_activity", "area_slugs" => ["dvorovi"], **notice_window,
                         "notices" => notice_window, "reports" => { "starts_at" => "2026-08-31T12:00:00Z", "ends_at" => NOW.iso8601 },
                         "activities" => { "starts_at" => NOW.iso8601, "ends_at" => "2026-09-14T12:00:00Z" } }
            evidence = capture_neighborhood(result(coverage:, validity: notice_window.merge("service_day" => "2026-09-07")))
            assert_equal({ "area_slugs" => ["dvorovi"] }, evidence.fetch("scope"))
            with_renderer do |runner, context, state, reads|
              state.merge!("active_task" => "ask_information", "topic" => "neighborhood", "prior_evidence" => evidence)
              date = runner.prior_evidence_follow_up(kind: "date", state:, context:, message: "Za koji datum važi?")
              refute_includes date.reply.text, I18n.t("decidim.bih.dialogue.prior_evidence_requested_window", locale: :sr, time: "").strip
              assert_includes date.reply.text, HUMAN.fetch("2026-09-08T08:00:00Z")
              assert_includes date.reply.text, HUMAN.fetch("2026-09-06")
              assert_empty reads
            end

            matching = coverage.merge("reports" => notice_window, "activities" => notice_window)
            assert_equal({ "area_slugs" => ["dvorovi"] }.merge(notice_window), capture_neighborhood(result(coverage: matching)).fetch("scope"))
            missing = matching.merge("activities" => { "status" => "unavailable" })
            assert_equal({ "area_slugs" => ["dvorovi"] }, capture_neighborhood(result(coverage: missing)).fetch("scope"))
            direct = coverage.merge("scope" => "collected_public_service_notices")
            assert_equal({ "area_slugs" => ["dvorovi"] }.merge(notice_window), capture_neighborhood(result(coverage: direct)).fetch("scope"))
          end

          def test_public_render_source_and_date_followups_use_metadata_without_rereading
            with_renderer do |runner, context, state, reads|
              @renderer_result = Contracts::ReadResult.new(
                status: "stale", facts: [fact("kind" => "city_service_event", "text" => "Public fixture notice", "checked_at" => NOW.iso8601)],
                coverage: { "scope" => "collected_public_neighborhood_activity", "area_slugs" => ["dvorovi"], "area_labels" => ["Dvorovi"] },
                validity: { "starts_at" => "2026-09-08T00:00:00Z", "ends_at" => "2026-09-09T00:00:00Z" }
              )
              input = Contracts::Understanding.parse(action: "ask_information", topic: "neighborhood", operation: "start",
                                                       entities: { "area_query" => "Dvorovi" }, locale: "sr", needs_clarification: false, secondary: nil)
              rendered = runner.call(understanding: input, state:, context:, message: "Šta se dešava u Dvorovima?")
              assert_equal "answered", rendered.resolution
              assert_includes rendered.reply.text, "Public fixture notice"
              metadata = rendered.state.fetch("prior_evidence")
              assert_equal "public_read", metadata.fetch("kind")
              @renderer_result = nil # Follow-ups must use retained public metadata, not a new port request.
              source = runner.prior_evidence_follow_up(kind: "source", state: rendered.state, context:, message: "Odakle ti to?")
              date = runner.prior_evidence_follow_up(kind: "date", state: source.state, context:, message: "Za koji datum važi?")
              assert_equal "answered", source.resolution
              assert_equal "answered", date.resolution
              assert_includes source.reply.text, "Water operator"
              assert_includes date.reply.text, HUMAN.fetch("2026-09-08T08:00:00Z")
              assert_includes date.reply.text, HUMAN.fetch("2026-09-06")
              assert_includes date.reply.text, HUMAN.fetch(NOW.iso8601)
              refute_match(/\d{4}-\d{2}-\d{2}/, date.reply.text)
              assert_equal "2026-09-08T08:00:00Z", metadata.dig("facts", 0, "starts_at")
              [source, date].each do |followup|
                assert_includes followup.reply.text, I18n.t("decidim.bih.dialogue.stale", locale: :sr)
                refute_includes followup.reply.text, "Public fixture notice"
                assert_equal metadata, followup.state.fetch("prior_evidence")
                assert_equal "ask_information", followup.state.fetch("active_task")
                refute followup.handoff_completed
              end
              assert_equal 1, reads.length
            end
          end

          def test_member_board_still_requires_current_access_and_cannot_be_captured_as_public
            board = result(coverage: { "visibility" => "member_board", "scope" => "area_public_reports", "area_slugs" => ["dvorovi"] })
            assert_nil capture_neighborhood(board)
            evidence = PriorEvidence.capture(result: board, facts: [fact], action: "neighborhood_information", topic: "neighborhood",
                                             now: NOW, expires_at: NOW.to_f + 60)
            assert_equal "member_board", evidence.fetch("kind")
            assert_raises(Contracts::Invalid) do
              PriorEvidence.normalize(evidence.merge("action" => "ask_information"), now: NOW, state_expires_at: NOW.to_f + 60)
            end
            with_renderer do |runner, context, state, reads|
              state.merge!("active_task" => "neighborhood_information", "topic" => "neighborhood", "prior_evidence" => evidence)
              @renderer_result = Contracts::ReadResult.new(status: "not_authorized")
              answer = runner.prior_evidence_follow_up(kind: "source", state:, context:, message: "Odakle ti to?")
              assert_equal "clarification", answer.resolution
              refute_includes answer.reply.text, "Water operator"
              assert_nil answer.state.fetch("prior_evidence")
              assert_equal 1, reads.length
              assert_equal "neighborhood_information", reads.first.fetch(:action)
              assert_equal({ "area_slug" => "dvorovi" }, reads.first.fetch(:entities))
            end
          end

          private

          def capture_neighborhood(read, facts: [fact])
            PriorEvidence.capture(result: read, facts:, action: "ask_information", topic: "neighborhood", now: NOW, expires_at: NOW.to_f + 60)
          end

          def with_renderer
            previous_backend = I18n.backend
            previous_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            I18n.backend = I18n::Backend::Simple.new
            %w(decidim_bih_dialogue.yml decidim_bih_dialogue_completion.yml).each do |file|
              I18n.backend.load_translations(File.expand_path("../../../../../../config/locales/#{file}", __dir__))
            end
            context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: NOW, capabilities: ["public_reads"])
            reads = []
            runner = ProcedureRunner.new(
              read_port: lambda { |**args| reads << args; @renderer_result || flunk("Unexpected evidence read") },
              registration_port: ->(**) { flunk "Unexpected authentication handoff" },
              destinations: { report: "/mi/prijavi", account: "/mi/moj-nalog", neighborhood: "/mi/komsiluk", support: "/pages/pomoc" }
            )
            yield runner, context, StateStore.new.empty_state(context), reads
          ensure
            I18n.backend = previous_backend
            I18n.available_locales = previous_locales
          end
        end
      end
    end
  end
end

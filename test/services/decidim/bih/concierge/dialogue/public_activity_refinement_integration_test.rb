# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class PublicActivityRefinementIntegrationTest < Minitest::Test
          def setup
            @old_backend = I18n.backend
            @old_locales = I18n.available_locales
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.backend.load_translations(*Dir[File.expand_path("../../../../../../config/locales/decidim_bih_dialogue*.yml", __dir__)])
            @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "f" * 64,
                                                     now: Time.utc(2026, 9, 10, 12), capabilities: ["public_reads"])
            @reads = []
            @runner = ProcedureRunner.new(read_port: lambda { |**args|
              @reads << args
              empty_public_read(args)
            },
                                          registration_port: ->(**) { raise "Unexpected account operation" },
                                          destinations: { report: "/reports", account: "/account", neighborhood: "/board", support: "/help" })
          end

          def teardown
            I18n.backend = @old_backend
            I18n.available_locales = @old_locales
          end

          def test_answered_area_then_weekend_refinements_keep_scope_and_render_empty_coverage_in_every_locale
            %w(neighborhood volunteer).product(Contracts::LOCALES).each do |topic, locale|
              state = answered_state(topic:, locale:)
              saved = state.fetch("suspended_task")
              assert_nil state["pending_slot"]

              area = refine("Ne, mislim na MZ Dvorovi", state:)
              assert_public_answer(area, topic:, area: "MZ Dvorovi", saved:)
              %w(area_slug street address).each { |key| refute @reads.last.fetch(:entities).has_key?(key) }
              assert_equal "2026-09-12", @reads.last.dig(:entities, "date")
              assert_equal "corrected", area.state.dig("entity_provenance", "area_query")
              # The saved report is offered once, on the first reply after the suspension.
              assert_includes area.reply.text, translated("resume_offer", locale:)
              assert_equal true, area.state.fetch("resume_offered")

              weekend = refine("A sljedećeg vikenda?", state: area.state)
              assert_public_answer(weekend, topic:, area: "MZ Dvorovi", saved:)
              assert_equal "sljedeceg vikenda", @reads.last.dig(:entities, "time_expression")
              refute weekend.state.fetch("entities").has_key?("date")
              refute weekend.state.fetch("entity_provenance").has_key?("date")
              assert_equal "corrected", weekend.state.dig("entity_provenance", "time_expression")

              assert_includes weekend.reply.text, "Dvorovi"
              if topic == "volunteer"
                # The catalogue's requested range is rendered by PublicCatalogEmptyAnswer (ISO dates).
                assert_includes weekend.reply.text, "2026-09-19"
                assert_includes weekend.reply.text, "2026-09-20"
              else
                # The summary's coverage window is rendered for humans; local midnight is a date.
                assert_includes weekend.reply.text, locale == "en" ? "19 Sep 2026" : "19.9.2026."
                assert_includes weekend.reply.text, locale == "en" ? "21 Sep 2026" : "21.9.2026."
                refute_includes weekend.reply.text, "12.9.2026."
              end
              refute_includes weekend.reply.text, "2026-09-12"
              refute_match(/translation missing|%\{/, weekend.reply.text)
              refute_includes weekend.reply.text, translated("resume_offer", locale:), "the resume offer is not repeated"
              if topic == "volunteer"
                assert_includes weekend.reply.text, translated("catalog_empty_scope_unavailable", locale:)
                assert_includes weekend.reply.text, translated("catalog_area_mz", locale:, name: "Dvorovi")
                assert_includes weekend.reply.text, translated("catalog_empty_limit", locale:)
                assert_includes weekend.reply.text, "Europe/Sarajevo"
              else
                %w(neighborhood_activity_scope_limited no_matching_public_activity).each do |code|
                  assert_includes weekend.reply.text, translated("read_warning_#{code}", locale:)
                end
                assert_includes weekend.reply.text, translated("neighborhood_activities_heading", locale:)
              end
            end
          end

          def test_day_refinement_retains_original_volunteer_query_category_and_owning_calendar_input
            state = answered_state(topic: "volunteer")
            state["entities"]["query"] = "Volonterske ekološke akcije koje se ponavljaju"
            # A model-invented task switch and scope must not overwrite this
            # closed citizen follow-up; the owning catalog still resolves time.
            model = Contracts::Understanding.parse(action: "ask_information", topic: "neighborhood", operation: "switch",
                                                   entities: { "area_query" => "MZ Janja", "date" => "2026-10-01" },
                                                   needs_clarification: false, secondary: nil, locale: "sr")
            answer = @runner.call(understanding: model, state:, context: @context, message: "A sutra?")
            assert_equal "answered", answer.resolution
            assert_equal "volunteer", @reads.last.fetch(:topic)
            assert_equal "sutra", @reads.last.dig(:entities, "time_expression")
            assert_equal "Komšiluk Dvorovi", @reads.last.dig(:entities, "area_query")
            assert_equal "environment", @reads.last.dig(:entities, "category")
            assert_equal state.dig("entities", "query"), @reads.last.dig(:entities, "query")
            refute @reads.last.fetch(:entities).has_key?("date")
            assert_equal state.fetch("suspended_task"), answer.state.fetch("suspended_task")
            assert_includes answer.reply.text, translated("catalog_empty_volunteer", locale: "sr")
            assert_includes answer.reply.text, "2026-09-11"
          end

          def test_private_board_and_draft_contexts_do_not_get_the_public_refinement_shortcut
            board = answered_state
            board["entities"]["query"] = "Objave na tabli mog komšiluka"
            draft = answered_state
            draft["draft"] = opaque_draft
            report = answered_state.merge("active_task" => "report_problem", "topic" => "report")
            [board, draft, report].each do |state|
              ["Ne, mislim na MZ Dvorovi", "A sljedećeg vikenda?"].each do |text|
                assert_nil ProcedureRunner.public_activity_continuation_input(text:, state:, locale: "sr")
                before = Marshal.dump(state)
                answer = @runner.call(understanding: Contracts::Understanding.clarify(locale: "sr"), state:, context: @context, message: text)
                assert_equal "clarification", answer.resolution
                assert_empty @reads
                assert_equal state.fetch("entities"), answer.state.fetch("entities")
                assert_equal state["draft"], answer.state["draft"] if state["draft"]
                assert_equal before, Marshal.dump(state)
              end
            end
          end

          def test_refinement_flag_is_request_local_and_never_bypasses_a_subsequent_board_read
            refined = refine("Ne, mislim na MZ Dvorovi", state: answered_state)
            assert_equal "ask_information", @reads.last.fetch(:action)
            input = Contracts::Understanding.parse(action: "ask_information", topic: "neighborhood", operation: "continue",
                                                   entities: { "query" => "Objave na tabli" }, needs_clarification: false, secondary: nil, locale: "sr")
            answer = @runner.call(understanding: input, state: refined.state, context: @context, message: "Objave na tabli")
            assert_equal "neighborhood_information", @reads.last.fetch(:action)
            assert_equal "handoff", answer.resolution
            assert_includes answer.reply.text, translated("not_authorized", locale: "sr", url: "/account")
            assert_empty answer.fact_ids
            assert_nil answer.state["prior_evidence"]
          end

          private

          def answered_state(topic: "neighborhood", locale: "sr")
            # An already answered empty public read can have a short model
            # paraphrase, with no positive activity regex or pending area slot.
            slots = { "query" => "Javna ponuda", "area_query" => "Komšiluk Dvorovi", "area_slug" => "komsiluk-55",
                      "street" => "Old street", "address" => "Old address", "category" => "environment", "date" => "2026-09-12" }
            saved = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge(
              "active_task" => "report_problem", "topic" => "report", "draft" => opaque_draft, "locale" => locale
            )
            StateStore.new.empty_state(@context).merge("active_task" => "ask_information", "topic" => topic, "locale" => locale,
                                                       "entities" => slots, "entity_provenance" => slots.transform_values { "citizen" }, "suspended_task" => saved)
          end

          def opaque_draft
            { "reference" => "public-test-draft-123", "revision" => 2, "expires_at" => @context.now.to_f + 300 }
          end

          def refine(text, state:)
            input = ProcedureRunner.public_activity_continuation_input(text:, state:, locale: state.fetch("locale"))
            refute_nil input
            assert_equal "correct", input.operation
            # The runner independently normalizes a generic model fallback,
            # matching the live failure instead of injecting the helper output.
            @runner.call(understanding: Contracts::Understanding.clarify(locale: state.fetch("locale")), state:, context: @context, message: text)
          end

          def assert_public_answer(answer, topic:, area:, saved:)
            assert_equal "answered", answer.resolution
            assert_equal "ask_information", @reads.last.fetch(:action)
            assert_equal topic, @reads.last.fetch(:topic)
            assert_equal area, @reads.last.dig(:entities, "area_query")
            assert_equal "environment", @reads.last.dig(:entities, "category")
            assert_equal "Javna ponuda", @reads.last.dig(:entities, "query")
            assert_equal saved, answer.state.fetch("suspended_task")
            assert_nil answer.state["pending_slot"]
            assert_nil answer.state["prior_evidence"]
            assert_empty answer.fact_ids
          end

          def empty_public_read(args)
            return Contracts::ReadResult.new(status: "not_authorized") if args.fetch(:action) == "neighborhood_information"

            entities = args.fetch(:entities)
            if args.fetch(:topic) == "neighborhood"
              # Synthetic owning-port output; this test proves rendering and
              # routing, while the host calendar test owns date calculation.
              first, last = entities["time_expression"] == "sljedeceg vikenda" ? %w(2026-09-19 2026-09-21) : %w(2026-09-12 2026-09-13)
              Contracts::ReadResult.new(status: "empty", coverage: { "scope" => "public_neighborhood_activities", "area_labels" => [entities.fetch("area_query")],
                                                                     "activities" => { "area_label" => entities.fetch("area_query"),
                                                                                       "starts_at" => "#{first}T00:00:00+02:00", "ends_at" => "#{last}T00:00:00+02:00" } },
                                        warnings: %w(neighborhood_activity_scope_limited no_matching_public_activity))
            else
              mz = entities.fetch("area_query").start_with?("MZ ")
              slug, kind = mz ? %w(dvorovi mz) : %w(komsiluk-55 komsiluk)
              validity = { "timezone" => "Europe/Sarajevo" }
              if entities["time_expression"] == "sljedeceg vikenda"
                validity.merge!("range_kind" => "weekend", "requested_dates" => { "from" => "2026-09-19", "through" => "2026-09-20" })
              else
                validity["requested_date"] = entities["date"] || "2026-09-11"
              end
              Contracts::ReadResult.new(status: "empty", source: { "id" => "platform:volunteer", "label" => "Public catalog", "url" => "/volunteering" },
                                        coverage: { "access" => "public", "complete_inventory" => false, "requested_area_slugs" => [slug],
                                                    "requested_areas" => [{ "slug" => slug, "kind" => kind, "label" => "Dvorovi" }] },
                                        validity:, warnings: mz ? ["mz_to_opportunity_crosswalk_not_reviewed"] : [])
            end
          end

          def translated(key, locale:, **values)
            I18n.t("decidim.bih.dialogue.#{key}", locale:, raise: true, **values)
          end
        end
      end
    end
  end
end

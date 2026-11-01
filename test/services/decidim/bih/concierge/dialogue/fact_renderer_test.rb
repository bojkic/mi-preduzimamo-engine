# frozen_string_literal: true

require "test_helper"
require "yaml"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/fact_renderer"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/contracts"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Unit coverage for the composition the renderer owns: the shape of an
        # answer, the budget it is composed to, where citations are grouped and
        # what a brevity request does to an answer already given.
        #
        # The whole-turn proof that a reply did not change by accident is
        # characterisation_test.rb; this file pins the rules.
        class FactRendererTest < Minitest::Test
          NOW = Time.utc(2026, 9, 14, 10, 30)
          # The default budget is 1-3 sentences, at most three items and
          # preferably 600 characters. These are the only reasons an answer is
          # allowed past it, and each one is content a citizen acts on:
          #
          #   1. a safety or emergency instruction;
          #   2. consent or terms text a citizen is agreeing to;
          #   3. a price, tariff or amount;
          #   4. a URL (never wrapped, never shortened);
          #   5. the source, check-time and coverage qualification of a fact
          #      that is shown — honesty about provenance is not decoration;
          #   6. a read warning that limits what the answer may be relied on
          #      for, including several at once for a multi-part read.
          #
          # Anything else that pushes an answer over the budget is a defect in
          # the composition, not an exception.
          BUDGET_EXCEPTIONS = %w(
            safety_or_emergency_instruction consent_or_terms price_or_amount url
            source_qualification read_warnings
          ).freeze

          # Only what the renderer is allowed to ask the turn for.
          class FakeTurn
            attr_reader :state, :message

            def initialize(green: false, locale: "sr", message: nil)
              @green = green
              @state = { "locale" => locale }
              @message = message
            end

            def t(key, **values)
              values.empty? ? "[#{key}]" : "[#{key} #{values.sort.map { |name, value| "#{name}=#{value}" }.join(",")}]"
            end

            def human_time(value) = "<#{value}>"

            def green_topic? = @green
          end

          # The same narrow surface, but with the SHIPPED Serbian wording and
          # the real TimeText, against a clock this test fixes. A date defect
          # cannot be pinned by a turn that stubs both the sentence and the
          # clock: "15.9.2026." is only wrong relative to a known today.
          class RealTimeTurn < FakeTurn
            DIALOGUE = YAML.safe_load_file(
              File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)
            ).fetch("sr").fetch("decidim").fetch("bih").fetch("dialogue").freeze

            def initialize(now:, **)
              super(**)
              @now = now
            end

            def t(key, **values)
              values.inject(DIALOGUE.fetch(key.to_s)) { |text, (name, value)| text.gsub("%{#{name}}", value.to_s) }
            end

            def human_time(value) = TimeText.call(value, locale: state.fetch("locale"), now: @now)
          end

          def setup
            @turn = FakeTurn.new
            @renderer = FactRenderer.new(@turn)
          end

          def fact(**extra)
            { "id" => "notice:1", "text" => "Radovi u Dvorovima.", "source_id" => "vodovod",
              "source_label" => "Vodovod", "source_url" => "https://vodovod.example/x" }.merge(extra)
          end

          def test_a_fact_renders_text_then_source_then_freshness_then_a_safe_url
            rendered = @renderer.render_fact(fact("checked_at" => "2026-09-14T06:00:00Z", "service_day" => "2026-09-15"))

            assert_equal [
              "Radovi u Dvorovima.", "[source source=Vodovod]", "[checked_at time=<2026-09-14T06:00:00Z>]",
              "[fact_service_day time=<2026-09-15>]", "https://vodovod.example/x"
            ].join("\n"), rendered
          end

          def test_structured_nearest_stop_brevity_keeps_map_caveat_and_source
            parts = { "body" => "Hospital stop. Position is approximate; check the stop sign. Choose the start in Maps",
                      "route_guidance" => ", and name a destination to select a bus line", "ending" => ".",
                      "caveat" => " I cannot verify step-free access." }
            navigation = fact("kind" => "transport_navigation", "source_id" => "public_transport_stop_registry",
                              "source_label" => "Reviewed stop registry", "source_url" => "https://city.example/stop-map.png",
                              "destination" => "https://www.google.com/maps/dir/?api=1&destination=44.750503%2C19.220973&travelmode=walking",
                              "navigation_presentation" => parts)
            navigation["text"] = "#{parts.values_at("body", "route_guidance", "ending", "caveat").join}\n#{navigation["destination"]}"
            default = @renderer.render_fact(navigation)
            assert_equal @renderer.render_fact(navigation.except("navigation_presentation")), default
            %w(short brief).each do |level|
              compact = FactRenderer.new(@turn, level:).render_fact(navigation)
              assert_operator compact.length, :<, default.length
              assert_includes compact, "Position is approximate; check the stop sign"
              assert_includes compact, "Choose the start in Maps."
              assert_includes compact, parts["caveat"]
              assert_includes compact, navigation["destination"]
              assert_includes compact, navigation["source_url"]
              assert_includes compact, "Reviewed stop registry"
              refute_includes compact, "select a bus line"
            end
          end

          def test_navigation_brevity_declines_partial_or_changed_shapes
            parts = { "body" => "Stop. Approximate position", "route_guidance" => ", choose a bus destination", "ending" => ".", "caveat" => "" }
            navigation = fact("kind" => "transport_navigation", "source_id" => "public_transport_stop_registry",
                              "destination" => "https://maps.example/stop", "navigation_presentation" => parts,
                              "text" => "Stop. Approximate position, choose a bus destination.\nhttps://maps.example/stop")
            variants = [navigation.merge("text" => "#{navigation["text"]}\nDo not cross this road."),
                        navigation.merge("navigation_presentation" => parts.except("caveat")),
                        navigation.merge("navigation_presentation" => parts.merge("extra" => "hidden")),
                        navigation.merge("navigation_presentation" => parts.merge("ending" => "!")),
                        navigation.merge("navigation_presentation" => parts.merge("body" => nil)),
                        navigation.merge("kind" => "transport_leg"), navigation.merge("source_id" => "other")]
            variants.each do |variant|
              assert_equal @renderer.render_fact(variant), FactRenderer.new(@turn, level: "short").render_fact(variant)
            end
          end

          def test_a_fact_falls_back_to_its_source_id_and_refuses_an_unsafe_url
            rendered = @renderer.render_fact(fact("source_label" => "  ", "source_url" => "javascript:alert(1)"))

            assert_equal "Radovi u Dvorovima.\n[source source=vodovod]", rendered
          end

          def test_safe_url_accepts_https_and_local_paths_only
            assert @renderer.safe_url?("https://example.org/a")
            assert @renderer.safe_url?("/mi/prijavi")
            refute @renderer.safe_url?("http://example.org")
            refute @renderer.safe_url?("https://user:pw@example.org")
            refute @renderer.safe_url?("//example.org")
          end

          def test_a_single_source_envelope_is_the_only_one_used
            assert_equal({ "id" => "a" }, @renderer.single_source(result(source: { "id" => "a" })))
            assert_equal({ "id" => "a" }, @renderer.single_source(result(source: [{ "id" => "a" }])))
            assert_empty @renderer.single_source(result(source: [{ "id" => "a" }, { "id" => "b" }]))
          end

          # The caveat exists so an English reader can check a Serbian
          # quotation against its source. An answer that cites no source has
          # nothing to check, so the sentence would be pure plumbing.
          def test_the_source_language_note_is_added_for_english_replies_that_cite_a_source
            english = FactRenderer.new(FakeTurn.new(locale: "en"))

            assert_equal "Answer\n[source source=X]", @renderer.with_source_language_note("Answer\n[source source=X]"),
                         "a Serbian reply never carries the note"
            assert_equal "Answer", english.with_source_language_note("Answer"), "no citation, no caveat"
            assert_equal "[facts_in_source_language]\n\nAnswer\n[source source=X]",
                         english.with_source_language_note("Answer\n[source source=X]")
          end

          def test_result_evidence_appends_source_check_time_coverage_and_warnings
            answer = @renderer.with_result_evidence("Odgovor", result(
                                                                 source: { "id" => "vodovod", "label" => "Vodovod" },
                                                                 checked_at: NOW, coverage: { "area_slugs" => ["dvorovi"] },
                                                                 warnings: %w(measurement_stale)
                                                               ))

            assert_equal [
              "Odgovor", "[source source=Vodovod]", "[checked_at time=<#{NOW}>]",
              "[coverage coverage_text=Dvorovi]", "", "[read_warning_old_measurement]"
            ].join("\n"), answer
          end

          # An internal identifier is not a place name, and a citizen who is
          # told "mz-dasnica" cannot tell whether that is their komšiluk.
          def test_an_area_slug_is_rendered_as_a_place_name_not_an_identifier
            with_translations(:catalog_area_mz) do
              answer = @renderer.with_result_evidence("Odgovor", result(coverage: { "area_slugs" => %w(mz-centar dvorovi) }))

              assert_includes answer, "[coverage coverage_text=[catalog_area_mz name=Centar]; Dvorovi]"
              refute_includes answer, "mz-centar"
            end
          end

          # Without the catalogue's wording the slug is still a place name,
          # and an abbreviation is not written out as an ordinary word.
          def test_a_place_name_falls_back_without_the_catalogue_wording
            # Deterministic about the catalogue key being absent: another test
            # in the suite appends the engine locales to I18n.load_path and
            # never removes them, which would otherwise flip I18n.exists? and
            # route this through the turn's translator.
            answer = I18n.stub(:exists?, false) do
              @renderer.with_result_evidence("Odgovor", result(coverage: { "area_slugs" => %w(mz-centar komsiluk-dvorovi) }))
            end

            assert_includes answer, "[coverage coverage_text=MZ Centar; Komsiluk Dvorovi]"
          end

          # A slug is ASCII Latin; a Cyrillic reply that quoted one came out
          # half in each script.
          def test_a_place_name_follows_the_reply_script
            cyrillic = FactRenderer.new(FakeTurn.new(locale: "sr-Cyrl"))
            # See above: pin the catalogue key as absent so this asserts the
            # script-following fallback it is named for, in any test order.
            answer = I18n.stub(:exists?, false) do
              cyrillic.with_result_evidence("Одговор", result(coverage: { "area_slugs" => ["mz-dasnica"] }))
            end

            assert_includes answer, "МЗ Дасница"
          end

          def test_an_unmapped_warning_becomes_the_coverage_limit_except_on_a_green_topic
            unmapped = result(warnings: %w(something_new))

            assert_equal "Odgovor\n\n[coverage_limit]", @renderer.with_result_evidence("Odgovor", unmapped)
            green = FactRenderer.new(FakeTurn.new(green: true))

            assert_equal "Odgovor", green.with_result_evidence("Odgovor", unmapped)
          end

          # The shape choice is behaviour: summary, then compacted events, then
          # compacted water levels, else the fact list.
          def test_available_read_picks_the_neighborhood_summary_first
            summary = result(status: "ok", coverage: { "scope" => "area_public_reports", "area_labels" => ["Dvorovi"] },
                             facts: [fact("kind" => "area_public_report")])
            rendered = @renderer.available_read(summary, summary.facts)

            assert rendered.compact
            assert_includes rendered.text, "[neighborhood_summary_heading area=Dvorovi]"
          end

          def test_available_read_compacts_water_levels_and_marks_the_answer_compact
            facts = [{ "id" => "wl:1", "kind" => "water_level_observation", "text" => "Drina 212 cm.",
                       "observed_at" => "2026-09-14T06:00:00Z", "source_id" => "rhmz", "source_label" => "RHMZ" }]
            water = result(status: "ok", validity: { "answer_shape" => "water_level_v1" }, facts:)
            rendered = @renderer.available_read(water, water.facts)

            assert rendered.compact
            assert_equal ["Drina 212 cm.\n[fact_observed_at time=<2026-09-14T06:00:00Z>]", "[source source=RHMZ]"].join("\n\n"), rendered.text
          end

          def test_a_single_fact_keeps_exactly_the_block_render_fact_produces
            plain = result(status: "ok", facts: [fact])
            rendered = @renderer.available_read(plain, plain.facts)

            refute rendered.compact, "the fact list is the shape whose caller appends the result evidence"
            assert_equal @renderer.render_fact(plain.facts.first), rendered.text
          end

          # The measured defect: eight rewards, the same URL eight times. One
          # provenance footer covers every item that shares it.
          def test_facts_from_one_source_are_cited_once_not_once_per_item
            plain = result(status: "ok", facts: [fact, fact("id" => "notice:2", "text" => "Druga obavijest.")])
            rendered = @renderer.available_read(plain, plain.facts)

            assert_equal 1, rendered.text.scan("[source source=Vodovod]").length
            assert_equal 1, rendered.text.scan("https://vodovod.example/x").length
            assert_includes rendered.text, "Radovi u Dvorovima."
            assert_includes rendered.text, "Druga obavijest."
          end

          # Source, time AND geographic scope must match before two items may
          # share one citation.
          def test_a_different_source_time_or_area_keeps_its_own_citation
            plain = result(status: "ok", facts: [
                             fact("checked_at" => "2026-09-14T06:00:00Z"),
                             fact("id" => "notice:2", "text" => "Druga.", "checked_at" => "2026-09-13T06:00:00Z"),
                             fact("id" => "notice:3", "text" => "Treća.", "source_id" => "elektro", "source_label" => "Elektro")
                           ])
            rendered = @renderer.available_read(plain, plain.facts)

            assert_equal 2, rendered.text.scan("[source source=Vodovod]").length
            assert_equal 1, rendered.text.scan("[source source=Elektro]").length
          end

          # A link is where THAT notice lives, not who published the group, so
          # one source publishing eight different documents is still one
          # citation — with eight links, each on its own item.
          def test_per_item_links_survive_a_shared_citation
            plain = result(status: "ok", facts: [
                             fact("id" => "pdf:1", "text" => "Izvještaj 10.9.", "source_url" => "https://vodovod.example/a.pdf"),
                             fact("id" => "pdf:2", "text" => "Izvještaj 9.9.", "source_url" => "https://vodovod.example/b.pdf")
                           ])
            rendered = @renderer.available_read(plain, plain.facts)

            assert_equal 1, rendered.text.scan("[source source=Vodovod]").length
            assert_includes rendered.text, "Izvještaj 10.9.\nhttps://vodovod.example/a.pdf"
            assert_includes rendered.text, "Izvještaj 9.9.\nhttps://vodovod.example/b.pdf"
          end

          def test_per_item_observation_and_validity_times_survive_grouping
            plain = result(status: "ok", facts: [
                             fact("observed_at" => "2026-09-14T06:00:00Z"),
                             fact("id" => "notice:2", "text" => "Druga.", "observed_at" => "2026-09-13T06:00:00Z")
                           ])
            rendered = @renderer.available_read(plain, plain.facts)

            assert_includes rendered.text, "[fact_observed_at time=<2026-09-14T06:00:00Z>]"
            assert_includes rendered.text, "[fact_observed_at time=<2026-09-13T06:00:00Z>]"
          end

          def test_available_read_appends_the_stale_line_to_either_shape
            stale = result(status: "stale", facts: [fact])

            assert_includes @renderer.available_read(stale, stale.facts).text, "\n\n[stale]"
          end

          def test_service_events_are_grouped_under_one_provenance_with_shared_qualifiers
            events = [service_event("ev:1", "Radovi u Dvorovima.", { "window" => "8-14", "scope" => "naselje" }),
                      service_event("ev:2", "Zamjena ventila.", { "window" => "8-14" })]
            grouped = result(status: "ok", facts: events)
            rendered = @renderer.available_read(grouped, grouped.facts)

            assert rendered.compact
            assert_includes rendered.text, "[notice_shared_qualifiers qualifiers=8-14]"
            assert_includes rendered.text, "Radovi u Dvorovima. naselje"
            assert_equal 1, rendered.text.scan("[source source=Vodovod]").length, "one provenance block for the whole group"
          end

          # == The item budget

          def test_more_items_than_the_budget_are_stated_as_a_count_behind_the_same_link
            facts = (1..9).map { |index| fact("id" => "notice:#{index}", "text" => "Nagrada #{index}.") }
            plain = result(status: "ok", facts:)
            rendered = @renderer.available_read(plain, plain.facts)

            assert_includes rendered.text, "Nagrada 3."
            refute_includes rendered.text, "Nagrada 4."
            assert_includes rendered.text, "[more_items shown=3,total=9]"
            assert_equal 1, rendered.text.scan("https://vodovod.example/x").length
          end

          # Ordering is not routing: the read decides which facts exist, the
          # renderer decides which three of them a citizen sees first.
          def test_the_item_the_citizen_asked_about_is_shown_first
            facts = %w(naljepnice zahvalnica torba pozivnica majica kupon radionica termos).each_with_index.map do |name, index|
              fact("id" => "reward:#{index}", "text" => "MI! #{name}: opis nagrade.")
            end
            renderer = FactRenderer.new(FakeTurn.new(message: "Koliko bodova košta MI majica?"))
            plain = result(status: "ok", facts:)

            rendered = renderer.available_read(plain, plain.facts)

            assert_includes rendered.text, "MI! majica"
            assert_includes rendered.text, "[more_items shown=3,total=8]"
          end

          def test_a_question_that_matches_nothing_keeps_the_sources_own_order
            facts = (1..5).map { |index| fact("id" => "n:#{index}", "text" => "Stavka #{index}.") }
            renderer = FactRenderer.new(FakeTurn.new(message: "Šta ima novo?"))
            plain = result(status: "ok", facts:)

            rendered = renderer.available_read(plain, plain.facts)

            assert_includes rendered.text, "Stavka 1."
            assert_includes rendered.text, "Stavka 3."
            refute_includes rendered.text, "Stavka 4."
          end

          # == The truncated restatement a teaser-publishing source produces

          def test_a_verbatim_restatement_of_a_truncated_teaser_is_printed_once
            teaser = "Dana 14. septembra 2026. godine, zbog otklanjanja kvarova na vodovodnoj mreži i priključenja n"
            full = "Dana 14. septembra 2026. godine, zbog otklanjanja kvarova na vodovodnoj mreži i priključenja novog " \
                   "korisnika, mogući su prekidi vodosnabdijevanja u ulici Baje Pivljanina."
            rendered = @renderer.render_fact(fact("text" => "Prekid vodosnabdijevanja: #{teaser}: #{full}"))

            assert_includes rendered, "Prekid vodosnabdijevanja: #{full}"
            assert_equal 1, rendered.scan("zbog otklanjanja kvarova").length
          end

          def test_two_different_notices_are_never_collapsed_into_one
            text = "Radovi u Dvorovima od 8 do 14 časova.\nZamjena ventila u ulici Svetog Save traje cijeli dan."
            rendered = @renderer.render_fact(fact("text" => text))

            assert_includes rendered, "Radovi u Dvorovima"
            assert_includes rendered, "Zamjena ventila"
          end

          # == Brevity

          def test_a_brevity_request_is_recognised_and_repeats_step_shorter
            assert_equal "default", FactRenderer.requested_level("Ima li danas prekida vode?")
            assert_equal "short", FactRenderer.requested_level("Kraće molim.")
            assert_equal "short", FactRenderer.requested_level("Кратко: до колико сати?")
            assert_equal "brief", FactRenderer.requested_level("Kraće molim.", current: "short")
            assert_equal "brief", FactRenderer.requested_level("Još kraće, u jednoj rečenici.")
            assert_equal "brief", FactRenderer.requested_level("U najviše 20 riječi: gdje se registrujem?")
            assert_equal "full", FactRenderer.requested_level("Daj mi cijeli spisak.")
            assert_equal "brief", FactRenderer.requested_level("Kraće.", current: "brief"), "the ladder has a floor"
          end

          def test_the_turns_own_message_sets_the_budget
            assert_equal "default", FactRenderer.new(FakeTurn.new(message: "Kada se odvozi smeće?")).level
            assert_equal "short", FactRenderer.new(FakeTurn.new(message: "Odgovori kratko: kada se odvozi smeće?")).level
            assert_equal "brief", FactRenderer.new(FakeTurn.new(message: "Odgovori u jednoj rečenici.")).level
            assert_equal "full", FactRenderer.new(FakeTurn.new(message: "Daj mi cijeli spisak."), level: "full").level
          end

          def test_a_shorter_budget_drops_optional_times_and_keeps_the_window_a_citizen_acts_on
            renderer = FactRenderer.new(FakeTurn.new(message: "Kratko: do koliko sati je najavljen prekid?"))
            rendered = renderer.render_fact(fact("source_published_at" => "2026-09-14T08:04:00Z",
                                                 "source_updated_at" => "2026-09-14T08:04:00Z",
                                                 "starts_at" => "2026-09-14T08:00:00Z",
                                                 "ends_at" => "2026-09-14T14:30:00Z"))

            assert_includes rendered, "[fact_ends_at time=<2026-09-14T14:30:00Z>]"
            assert_includes rendered, "[fact_starts_at time=<2026-09-14T08:00:00Z>]"
            refute_includes rendered, "fact_source_published_at"
            assert_includes rendered, "https://vodovod.example/x", "a URL is never what goes"
          end

          # "Kraće" is a presentation operation on the answer already given:
          # the same facts, the same qualification, materially shorter.
          def test_shorten_drops_whole_items_keeps_the_citation_and_says_how_many_are_left
            answer = [
              "Nagrada 1: opis.", "Nagrada 2: opis.", "Nagrada 3: opis.",
              "[source source=Katalog]\n[checked_at time=<danas>]\nhttps://mi.example/nagrade"
            ].join("\n\n")

            shorter = @renderer.shorten(answer, level: "short")

            assert_operator shorter.length, :<, answer.length
            assert_includes shorter, "Nagrada 1: opis."
            refute_includes shorter, "Nagrada 3: opis."
            assert_includes shorter, "[source source=Katalog]"
            assert_includes shorter, "https://mi.example/nagrade"
            assert_includes shorter, "[more_items shown=1,total=3]"
          end

          def test_a_second_shorten_is_shorter_again_and_still_carries_the_same_source
            answer = [
              "Odvoz otpada za „Patkovača“: srijeda, četvrtak. Ovo je posljednji raspored koji smo uspjeli provjeriti. " \
              "Promjene za praznike nisu potvrđene u ovom izvodu.",
              "Druga obavijest o istom rasporedu.",
              "[source source=Komunalac]\nhttps://komunalac.example/raspored"
            ].join("\n\n")

            once = @renderer.shorten(answer, level: "short")
            twice = @renderer.shorten(once, level: "brief")

            assert_operator once.length, :<, answer.length
            assert_operator twice.length, :<, once.length
            assert_includes twice, "Odvoz otpada za „Patkovača“: srijeda, četvrtak."
            assert_includes twice, "[source source=Komunalac]"
            assert_includes twice, "https://komunalac.example/raspored"
          end

          # The count is the truth about the whole catalogue. Recounting the
          # blocks of an already-shortened answer would shrink the total on
          # every step until it claimed the catalogue had two items in it.
          def test_a_count_the_answer_already_carries_is_never_recounted
            answer = ["Nagrada 1: opis.", "Nagrada 2: opis.", "Nagrada 3: opis.",
                      "[source source=Katalog]", "[more_items shown=3,total=9]"].join("\n\n")

            shorter = @renderer.shorten(answer, level: "short")

            assert_includes shorter, "[more_items shown=1,total=9]"
            assert_equal 1, shorter.scan("[more_items").length
          end

          def test_shorten_never_cuts_a_price_a_negation_or_consent_text
            answer = [
              "Zona 1 košta 1 KM po satu. Naplata ne važi nedjeljom. Parkiranje je besplatno za invalidska vozila.",
              "Prijavom prihvataš uslove korištenja.",
              "[source source=Parking servis]\nhttps://parking.example/zone"
            ].join("\n\n")

            shorter = @renderer.shorten(answer, level: "brief")

            assert_includes shorter, "1 KM po satu"
            assert_includes shorter, "Naplata ne važi nedjeljom."
            assert_includes shorter, "Prijavom prihvataš uslove korištenja."
            assert_includes shorter, "https://parking.example/zone"
          end

          def test_shorten_leaves_an_answer_that_is_already_minimal_alone
            answer = "Odvoz otpada: srijeda.\n[source source=Komunalac]"

            assert_equal answer, @renderer.shorten(answer, level: "brief")
          end

          def test_the_declared_budget_exceptions_are_the_only_ones
            assert_equal 6, BUDGET_EXCEPTIONS.length
            assert_equal BUDGET_EXCEPTIONS.uniq, BUDGET_EXCEPTIONS
            assert_equal 600, FactRenderer::BUDGETS.fetch("default").characters
            assert_equal 3, FactRenderer::BUDGETS.fetch("default").items
          end

          # A source catalogue's operator-facing label is an inventory entry,
          # not a name a citizen reads. The renderer asks for a localized name
          # first; the names themselves are the HOST's copy, because a city's
          # utilities are not the engine's business.
          def test_a_localized_source_name_replaces_the_catalogue_label
            with_translations(:source_name_water_service) do
              rendered = @renderer.render_fact(fact("source_id" => "water_service", "source_label" => "Vodovod service information"))

              assert_includes rendered, "[source source=[source_name_water_service]]"
              refute_includes rendered, "service information"
            end
          end

          def test_a_source_with_no_localized_name_keeps_its_label
            with_translations(:source_name_water_service) do
              rendered = @renderer.render_fact(fact("source_id" => "some_new_source", "source_label" => "Novi izvor"))

              assert_includes rendered, "[source source=Novi izvor]"
            end
          end

          def test_the_engine_ships_no_source_names_of_its_own
            dialogue = YAML.safe_load_file(File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__))

            dialogue.each_value do |tree|
              keys = tree.fetch("decidim").fetch("bih").fetch("dialogue").keys

              assert_empty keys.grep(/\Asource_name_/), "a city's source names belong to the host, not the engine"
            end
          end

          # == R4: relevance before budget

          # "PM2.5" is the whole question. Text.fold turns it into "pm2 5" and
          # the four-character floor then threw both halves away, so the one
          # fact carrying the reading scored zero while every PDF link scored
          # on "vazduha" — and the measurement fell off the end of a 3-item
          # budget. Reproduced on production 14.09.2026 in 3 of 4 sends of
          # "Kolika je zagadjenost vazduha PM2.5 u Bijeljini?".
          def test_a_question_naming_a_measure_keeps_the_fact_that_carries_it
            facts = (1..7).map do |index|
              fact("id" => "pdf:#{index}", "text" => "Kvalitet vazduha: #{index}.9.2026. Poveznica na izvještaj; vrijednosti nisu izdvojene iz PDF-a.")
            end
            facts << fact("id" => "klimerko", "text" => "Bijeljina (Klimerko javni prikaz), PM2.5: 9 µg/m³.")
            renderer = FactRenderer.new(FakeTurn.new(message: "Kolika je zagadjenost vazduha PM2.5 u Bijeljini?"))
            plain = result(status: "ok", facts:)

            rendered = renderer.available_read(plain, plain.facts)

            assert_includes rendered.text, "PM2.5: 9 µg/m³", "the measurement the question named was dropped for the budget"
            assert_includes rendered.text, "[more_items shown=3,total=8]"
          end

          # The identifier outranks the topic word, so the reading is FIRST and
          # not merely retained: ranking it level with "vazduha" left it behind
          # seven facts that also match, which is the defect.
          def test_a_named_measure_outranks_a_topic_word
            facts = [fact("id" => "pdf:1", "text" => "Kvalitet vazduha u Bijeljini: izvještaj u PDF-u."),
                     fact("id" => "klimerko", "text" => "Klimerko javni prikaz, PM2.5: 9.")]
            renderer = FactRenderer.new(FakeTurn.new(message: "Kolika je zagadjenost vazduha PM2.5?"))

            ordered = renderer.send(:relevance_ordered, facts)

            assert_equal %w(klimerko pdf:1), (ordered.map { |item| item.fetch("id") })
          end

          def test_a_measure_identifier_survives_the_token_cap_and_the_length_floor
            renderer = FactRenderer.new(FakeTurn.new(message: "Kakve su vrijednosti PM10 i NO2 u vazduhu danas?"))

            assert_includes renderer.send(:question_tokens), "pm10"
            assert_includes renderer.send(:question_tokens), "no2"
          end

          # A bare number is a year, a price or a house number. Treated as an
          # identifier it would outrank the topic word in every fact a source
          # has ever dated, which is the opposite of the fix.
          def test_a_bare_number_is_not_a_measure_identifier
            renderer = FactRenderer.new(FakeTurn.new(message: "Koliki je PM2.5 u 2026?"))

            refute renderer.send(:identifying_token?, "2026")
            assert renderer.send(:identifying_token?, "pm2")

            facts = [fact("id" => "dated", "text" => "Program za 2026. godinu."),
                     fact("id" => "klimerko", "text" => "Klimerko javni prikaz, PM2.5: 9.")]

            assert_equal %w(klimerko dated), (renderer.send(:relevance_ordered, facts).map { |item| item.fetch("id") })
          end

          # == R8: the word the reply asks for is the word that works

          # "Prikaz: 3/8. Za cijeli spisak napiši „više“" printed under every
          # truncated answer, and „više“ was the one phrasing MORE_REQUEST did
          # not carry: it re-ran the same read at the same budget and returned
          # the same three items. Verified on production 14.09.2026 — "cijeli
          # spisak" expanded 3/8 to all eight, „više“ did not.
          def test_the_word_the_more_items_line_asks_for_expands_the_list
            %w(više vise још jos more).each do |word|
              assert_equal "full", FactRenderer.requested_level(word), "„#{word}“ alone must open the full list"
            end
          end

          # Inside a sentence the same word is not that request: one cancels,
          # one asks about a count.
          def test_the_bare_word_is_the_request_and_a_sentence_containing_it_is_not
            assert_equal "default", FactRenderer.requested_level("Neću više!")
            assert_equal "default", FactRenderer.requested_level("Imam li više od 5 prijava?")
            assert_equal "full", FactRenderer.requested_level("Daj mi cijeli spisak."), "the phrases still work"
          end

          # == R8: a validity window is a period, not an event date

          # "Područje i vrijeme: MZ Dasnica; danas u 19:08; 15.9.2026. u 07:08"
          # was printed on 14.09.2026 — the second time is the END of the
          # twelve-hour window the read was run over, and printed bare it reads
          # as the day the thing happens. A period must be worded as a period.
          def test_a_requested_window_is_rendered_as_one_period_not_two_event_times
            # See the place-name tests above: another file in this suite leaves
            # the engine locales on I18n.load_path, so the catalogue wording is
            # pinned absent to keep this test about the window in any order.
            answer = I18n.stub(:exists?, false) do
              @renderer.with_result_evidence("Odgovor", result(
                                                          coverage: { "area_slugs" => ["mz-dasnica"] },
                                                          validity: { "starts_at" => "2026-09-14T17:08:00Z",
                                                                      "ends_at" => "2026-09-15T05:08:00Z" }
                                                        ))
            end

            assert_includes answer,
                            "[coverage coverage_text=MZ Dasnica; [coverage_window from=<2026-09-14T17:08:00Z>,to=<2026-09-15T05:08:00Z>]]"
            refute_includes answer, "; <2026-09-15T05:08:00Z>",
                            "the window's end was printed as if it were an event date"
          end

          # A lone endpoint is the same claim with half the evidence: say which
          # end it is.
          def test_a_lone_window_endpoint_says_which_end_it_is
            until_only = @renderer.with_result_evidence("Odgovor", result(validity: { "ends_at" => "2026-09-15T05:08:00Z" }))

            assert_includes until_only, "[coverage coverage_text=[coverage_until time=<2026-09-15T05:08:00Z>]]"

            from_only = @renderer.with_result_evidence("Odgovor", result(validity: { "starts_at" => "2026-09-14T17:08:00Z" }))

            assert_includes from_only, "[coverage coverage_text=[coverage_from time=<2026-09-14T17:08:00Z>]]"
          end

          # An observation or service day is NOT a window endpoint and keeps
          # its bare rendering: the distinction the defect erased is exactly
          # the one this pins.
          def test_an_observation_date_is_not_worded_as_a_window
            answer = @renderer.with_result_evidence("Odgovor", result(validity: { "reviewed_on" => "2026-06-29",
                                                                                  "service_day" => "2026-09-15" }))

            assert_includes answer, "[coverage coverage_text=<2026-09-15>; <2026-06-29>]"
            refute_includes answer, "coverage_window"
            refute_includes answer, "coverage_until"
          end

          # The clock is fixed, and the rendered window is the stored window —
          # never "now" and never a day later than the source said.
          def test_the_window_renders_the_stored_times_against_a_fixed_clock
            renderer = FactRenderer.new(RealTimeTurn.new(now: Time.utc(2026, 9, 14, 17, 8)))
            window = { "starts_at" => "2026-09-14T17:08:00Z", "ends_at" => "2026-09-15T05:08:00Z" }
            answer = renderer.with_result_evidence("Odgovor", result(validity: window))

            assert_includes answer, "Područje i vrijeme: od danas u 19:08 do 15.9.2026. u 07:08"
            refute_includes answer, "Područje i vrijeme: danas u 19:08; 15.9.2026."
          end

          # == R8: one check time per answer

          # Sistem 48's catalogue is a single fact whose check time equals the
          # result's, so "Provjereno: juče u 06:20" was printed twice in the
          # same 957-character reply.
          def test_the_result_check_time_is_not_repeated_when_the_fact_already_carried_it
            single = result(status: "ok", checked_at: NOW, source: { "id" => "sistem48", "label" => "Sistem 48" },
                            facts: [fact("checked_at" => NOW, "source_id" => "sistem48", "source_label" => "Sistem 48")])
            body = @renderer.available_read(single, single.facts).text
            answer = @renderer.with_result_evidence(body, single)

            assert_equal 1, answer.scan("[checked_at time=<#{NOW}>]").length,
                         "the same check time was printed twice"
          end

          def test_a_different_result_check_time_is_still_appended
            single = result(status: "ok", checked_at: NOW, source: { "id" => "sistem48", "label" => "Sistem 48" },
                            facts: [fact("checked_at" => "2026-09-13T06:20:00Z")])
            body = @renderer.available_read(single, single.facts).text
            answer = @renderer.with_result_evidence(body, single)

            assert_includes answer, "[checked_at time=<#{NOW}>]"
            assert_includes answer, "[checked_at time=<2026-09-13T06:20:00Z>]"
          end

          private

          # The host supplies some of these keys into the same namespace; a
          # unit test stands in for that without depending on a city's file.
          # The stored value is never read — FakeTurn#t stubs the rendering —
          # only I18n.exists? is, which is what the renderer branches on.
          def with_translations(*keys)
            previous = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            values = keys.to_h { |key| [key, "unused: the fake turn stubs the rendering"] }
            I18n.backend.store_translations("sr", { decidim: { bih: { dialogue: values } } })
            yield
          ensure
            I18n.available_locales = previous
            I18n.backend.reload!
          end

          def service_event(id, body, qualifiers)
            { "id" => id, "kind" => "city_service_event", "answer_shape" => "service_event_v1",
              "text" => ([body] + qualifiers.values).join(" "), "notice_body" => body, "notice_qualifiers" => qualifiers,
              "source_id" => "vodovod", "source_label" => "Vodovod" }
          end

          def result(status: "ok", **attributes)
            Contracts::ReadResult.new(status:, **attributes)
          end
        end
      end
    end
  end
end

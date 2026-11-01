# frozen_string_literal: true

require "uri"
require_relative "time_text"
require_relative "../../text"
require "decidim/bih/transliterator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # THE fact, source, freshness and grouping composition for a dialogue
        # reply. Task 0 extracted it from ProcedureRunner::Turn so that reply
        # shape has one owner instead of being spread through the runner.
        #
        # == Entry point and composition order
        #
        # FactRenderer.new(turn) is the one entry point; the turn supplies the
        # locale-bound helpers (+t+, +human_time+, +green_topic?+, +state+,
        # +message+) and nothing else. The renderer reads — it never writes
        # state, never calls a port and never decides a resolution.
        #
        # +available_read+ composes an answer in this order, which is behaviour:
        #   1. pick the shape — neighborhood summary, then compacted service
        #      events, then compacted water levels, else the fact list;
        #   2. prepend the source-language note (English replies only);
        #   3. append the "stale" line when the read was stale.
        # It returns Rendered(text:, compact:); +compact+ is false only for the
        # fact list, which is the one shape whose caller still appends the
        # result evidence (source, check time, coverage, warnings).
        #
        # == The budget is semantic, and it is applied BEFORE rendering
        #
        # A reply is composed to a Budget — how many items, how many optional
        # time qualifiers — and never chopped to a character count afterwards.
        # Citations are grouped, so one provenance footer covers every item
        # that shares a source, a check time AND a geographic scope; items that
        # do not fit are stated as a count behind the same link rather than
        # silently dropped. Nothing that carries meaning a citizen acts on — a
        # negation, a price, consent text, an emergency instruction or a URL —
        # is ever removed to fit; when such content puts an answer over the
        # character budget, that is a declared exception (see
        # fact_renderer_test.rb's BUDGET_EXCEPTIONS), not a hidden truncation.
        class FactRenderer
          Rendered = Data.define(:text, :compact)

          # +items+, +qualifiers+ and +sentences+ are composition limits;
          # +characters+ is what they aim at, never a cut-off. +sentences+ is
          # nil where a kept item is never reduced at all.
          Budget = Data.define(:items, :qualifiers, :characters, :sentences)
          BUDGETS = {
            "full" => Budget.new(items: 8, qualifiers: 8, characters: nil, sentences: nil),
            "default" => Budget.new(items: 3, qualifiers: 8, characters: 600, sentences: nil),
            "short" => Budget.new(items: 1, qualifiers: 2, characters: 300, sentences: 3),
            "brief" => Budget.new(items: 1, qualifiers: 1, characters: 160, sentences: 1)
          }.freeze
          DEFAULT_LEVEL = "default"
          # Ordered from longest to shortest: "kraće" steps one to the right.
          LEVELS = %w(full default short brief).freeze

          # Brevity is a presentation request, never a new task and never a
          # cancellation. Matched against Text.fold output, so "kraće",
          # "КРАЋЕ" and "krace" are the same request.
          SHORTEST_REQUEST = /\b(?:jos[ ]krace|jos[ ]sazetije|najkrace|u[ ]jednoj[ ]recenici|jednom[ ]recenicom|jedna[ ]recenica|
                               even[ ]shorter|much[ ]shorter|one[ ]sentence|single[ ]sentence)\b/x
          SHORTER_REQUEST = /\b(?:krace|kratko|ukratko|sazeto|sazetije|skraceno|briefly|in short|be brief|keep it short|shorter)\b/
          FIELD_ONLY_REQUEST = /\bsamo (?:naziv|ime|cijen|cijena|broj|datum|dan|sat|adres|kontakt|iznos)/
          WORD_LIMIT_REQUEST = /\bu najvise (\d{1,3}) (?:rijeci|reci|words?)\b/
          MORE_REQUEST = /\b(?:detaljnije|opsirnije|vise[ ]detalja|cijeli[ ]spisak|cijeli[ ]popis|ceo[ ]spisak|prikazi[ ]sve|sve[ ]stavke|
                            more[ ]detail|more[ ]details|full[ ]list|show[ ]all|show[ ]everything)\b/x
          # The word more_items itself tells the citizen to type. Only
          # "cijeli spisak" actually expanded the list, so the instruction
          # printed under every truncated answer did not work: „više“ re-ran
          # the same read at the same budget and returned the same three items.
          # Anchored to the WHOLE message, because inside a sentence the same
          # word is not this request — "neću više" cancels, and "više od 5
          # prijava" is a question about a count.
          MORE_WORD = /\A(?:vise|jos|more)\z/
          # One matcher, so asking for the full list stays one decision.
          FULL_LIST_REQUEST = Regexp.union(MORE_WORD, MORE_REQUEST).freeze
          # A word this short carries no selection value, and these carry none
          # at any length: they are how a question is phrased, not what it asks
          # about.
          QUESTION_STOPWORDS = %w(
            koliko kolika koliki koje koja koji kada kade gdje gdeje sada danas sutra molim mozes mozete
            bodova bodove bodovi kosta kostaju kostati cijena cijene imas imate ima nema
            dvije dvoje jedan jedna jedno prvi prva prvo najjeftinije najskuplje dostupne dostupno dostupna
            what when where which does have cost costs points cheapest available please
          ).freeze

          # A folded token that names one measurement rather than a topic:
          # letters bound to digits, in either order ("pm2", "pm10", "no2",
          # "so2", "5g"). Matched whole, so a bare year or amount is excluded.
          IDENTIFYING_TOKEN = /\A(?:[a-z]{1,4}\d{1,3}|\d{1,3}[a-z]{1,4})\z/

          QUALIFIER_KEYS = %w(observed_at reviewed_on source_published_at source_updated_at service_day starts_at ends_at valid_until).freeze
          # Which times survive a tighter budget: the window a citizen acts on
          # outranks the source's publication history.
          QUALIFIER_PRIORITY = %w(ends_at starts_at service_day valid_until observed_at reviewed_on source_published_at source_updated_at).freeze

          # A span this long, repeated verbatim immediately after itself, is a
          # source teaser restated by its own notice — never two real facts.
          MIN_RESTATEMENT = 40
          # Below this a fragment is a heading or a brand, not a sentence.
          MIN_SENTENCE = 25
          MAX_RESTATEMENT_HEADING = 80
          # An internal identifier shape: lowercase ASCII, no spaces.
          SLUG = /\A[a-z][a-z0-9]*(?:[-_][a-z0-9]+)*\z/
          # Slug prefixes that name an area kind the catalogue already words.
          AREA_KIND_PREFIXES = %w(mz komsiluk).freeze
          # Only where the catalogue's own wording is unavailable, so an
          # abbreviation is not silently written out as an ordinary word.
          AREA_KIND_ABBREVIATIONS = { "mz" => "MZ" }.freeze
          # Content that is never dropped to fit a budget, in any locale we
          # serve. A price is a price in every one of them; the consent and
          # emergency vocabulary is matched as a stem, and negation only ever
          # protects the sentence it is in — a notice that merely says "this
          # is not a confirmation" is not thereby exempt from the item budget.
          AMOUNT = Regexp.union(
            /\d[\d.,]*\s*(?:km\b|bam\b|kn\b|€|%|bod\w*|point\w*)/i,
            # "Cijena u bodovima: 250." puts the unit before the number.
            /(?:bod\w*|point\w*|cijen\w*|cost|price|iznos\w*|taks\w*|naknad\w*)\P{Nd}{0,15}\d/i
          ).freeze
          SAFETY_STEMS = %w(
            saglasnost pristanak privola uslov uvjet consent terms
            hitn opasn evakuac upozorenj spasav emergency urgent danger warning
          ).freeze
          EMERGENCY_NUMBERS = %w(112 121 122 123 124).freeze
          NEGATIONS = %w(ne nije nisu necu neces nemoj nemojte nema bez nikako nikad not no never cannot without).freeze
          MARKER = "\u0000"

          READ_WARNING_KEYS = {
            "conflicting_current_facts" => "conflicting_facts",
            "operator_reviewed_correction" => "operator_correction",
            "source_observation_not_area_status" => "observation_scope", "requested_area_not_supported_by_source" => "area_scope",
            "measurement_time_unknown" => "observation_time_unknown", "measurement_stale" => "old_measurement",
            "future_measurement_not_available" => "no_forecast", "measurement_time_in_future" => "unverified_measurement_time",
            "partial_source_coverage" => "partial_sources", "historical_snapshot_not_complete_series" => "partial_history",
            "latest_source_check_unavailable" => "check_unavailable", "procedure_source_changed_review_required" => "changed_source",
            "unspecified_fees_documents_deadlines_remain_unknown" => "procedure_incomplete",
            "planned_allocations_not_spending" => "budget_plan", "publication_not_effective_date" => "effective_date_unknown",
            "eligibility_must_be_checked_in_official_call" => "eligibility", "public_calls_with_unknown_dates_excluded" => "unknown_deadlines",
            "source_time_is_date_only" => "date_only", "planned_end_not_confirmed_restoration" => "planned_end",
            # Nine service-read outcomes that used to collapse into the one
            # generic coverage sentence, so "I do not know where you mean",
            # "nothing in the source covers that period" and "the provider is
            # unreachable" all reached the citizen as the same paragraph.
            "area_not_found" => "area_unresolved", "citywide_query_scope" => "citywide_scope",
            "street_coverage_not_published_by_source" => "street_not_published",
            "source_scope_or_time_not_matched" => "window_not_matched",
            "announcement_window_not_current_status" => "announcement_window",
            "no_matching_source_notice" => "reviewed_empty",
            "source_content_not_operator_reviewed" => "content_unreviewed",
            "source_extraction_incomplete" => "extraction_incomplete",
            "source_extraction_failed" => "extraction_failed",
            "source_publication_stale" => "publication_stale", "source_unavailable" => "source_down",
            "absence_not_evidence_of_normal_service" => "absence_not_normal_service"
          }.merge(%w(public_reports_recent_window public_reports_window public_reports_truncated public_reports_area_unavailable
                     public_reports_unavailable no_matching_public_reports no_matching_collected_notices neighborhood_notices_unavailable
                     public_directory_contact_not_live_verified neighborhood_unlocated_notices no_area_matched_collected_notices
                     neighborhood_activity_scope_limited no_matching_public_activity neighborhood_activity_unavailable
                     neighborhood_activity_mz_volunteer_unmapped neighborhood_activity_list_bounded neighborhood_activity_participation_on_page).to_h { |code| [code, code] }).freeze

          # +level+ overrides the level read out of this turn's own message, so
          # a caller that already resolved the request (Task 4 routing a
          # repeated "kraće") does not have to phrase it as citizen text.
          def initialize(turn, level: nil)
            @turn = turn
            @level = LEVELS.include?(level) ? level : self.class.requested_level(citizen_text)
          end

          attr_reader :level

          def budget = BUDGETS.fetch(@level)

          # The brevity level a message asks for, relative to the level already
          # in force. A repeated request steps one level shorter every time,
          # which is what makes a second "kraće" actually shorter.
          def self.requested_level(text, current: DEFAULT_LEVEL)
            current = DEFAULT_LEVEL unless LEVELS.include?(current)
            folded = Decidim::Bih::Text.fold(text.to_s)
            return current if folded.empty?
            return "full" if folded.match?(FULL_LIST_REQUEST)
            return "brief" if folded.match?(SHORTEST_REQUEST)

            words = folded[WORD_LIMIT_REQUEST, 1]
            return words.to_i <= 20 ? "brief" : "short" if words
            return step_shorter(current) if folded.match?(SHORTER_REQUEST) || folded.match?(FIELD_ONLY_REQUEST)

            current
          end

          def self.step_shorter(level)
            index = LEVELS.index(level) || LEVELS.index(DEFAULT_LEVEL)
            LEVELS.fetch([index + 1, LEVELS.length - 1].min)
          end

          # A local application path, never an absolute or host-bearing URL.
          # ProcedureRunner validates its destinations with the same rule.
          def self.safe_path?(value)
            value.is_a?(String) && value.start_with?("/") && !value.start_with?("//") &&
              !value.match?(/[\\\s\x00-\x1f]/) && URI.parse(value).host.nil?
          rescue URI::InvalidURIError
            false
          end

          # The rendering half of ProcedureRunner::Turn#render_available_read.
          def available_read(result, facts)
            compact = compact_water_read?(result, facts) || compact_service_events?(facts) || public_neighborhood_summary?(result)
            answer = if !compact
                       fact_list_text(facts)
                     elsif public_neighborhood_summary?(result)
                       neighborhood_summary_text(result, facts)
                     elsif compact_service_events?(facts)
                       compact_service_text(result, facts)
                     else
                       compact_water_text(result, facts)
                     end
            answer = with_source_language_note(answer)
            answer += "\n\n#{t("stale")}" if result.status == "stale"
            Rendered.new(text: answer, compact:)
          end

          # A repeated brevity request is a presentation operation on the
          # answer that was already given: the same facts, the same source
          # qualification, materially shorter. Task 4 routes the request; this
          # produces the shorter rendering, and applying it again goes shorter
          # again. It removes whole optional blocks and optional qualifier
          # lines — never a price, a negation, consent or emergency text, and
          # never a URL that has nowhere else to live.
          def shorten(answer, level: nil)
            target = BUDGETS.fetch(LEVELS.include?(level) ? level : self.class.step_shorter(@level))
            blocks = answer.to_s.split("\n\n")
            kept = []
            dropped = []
            carried = nil
            prose = 0
            blocks.each do |block|
              # A count this answer already carries is the truth about the
              # whole catalogue; recounting the blocks of a shortened answer
              # would shrink the total every time.
              if (total = carried_total(block))
                carried = total
                next
              end
              if provenance_block?(block) || safety_block?(block)
                kept << block
              elsif prose < target.items
                prose += 1
                kept << trimmed_block(block, target)
              else
                dropped << block
              end
            end
            finish_shortened(kept, dropped, blocks, carried)
          end

          def single_source(result)
            source = result.source
            source = source.first if source.is_a?(Array) && source.size == 1
            source.is_a?(Hash) ? source : {}
          end

          # Facts are quoted in their source's language, Serbian for every
          # reviewed city source. An English reply says so once, above the
          # fact block, so its English footers are not read as a translation
          # of the body. Local-language replies never carry the note, and
          # neither does an answer that cites no source: the caveat exists to
          # help a citizen verify a quotation, not to describe our plumbing.
          def with_source_language_note(answer)
            return answer unless state.fetch("locale") == "en"
            return answer unless cites_a_source?(answer)

            "#{t("facts_in_source_language")}\n\n#{answer}"
          end

          # +omit_warning+ is the one warning sentence the caller has already
          # printed as the answer itself. A checked-zero read answers WITH its
          # own warning sentence (Dialogue::CheckedZero), and repeating it in
          # the block below would read as two findings instead of one.
          def with_result_evidence(answer, result, include_source: true, omit_warning: nil)
            source = single_source(result)
            answer = append_result_source(answer, source) if include_source
            answer = with_result_check_time(answer, result)
            scope = evidence_scope(result)
            answer += "\n#{t("coverage", coverage_text: scope.join("; "))}" unless scope.empty?
            warnings = rendered_warnings(result, omit: omit_warning)
            answer += "\n\n#{warnings}" unless warnings.empty?
            answer
          end

          # One check time per answer. A single fact whose check time IS the
          # result's has already printed this exact line (Sistem 48's catalogue
          # printed "Provjereno" twice inside the same 957-character reply); a
          # fact checked at a different moment still gets both lines.
          def with_result_check_time(answer, result)
            return answer unless result.checked_at

            line = t("checked_at", time: human_time(result.checked_at))
            return answer if answer.include?(line)

            "#{answer}\n#{line}"
          end

          def rendered_warnings(result, omit: nil)
            return "" if result.warnings.empty?

            keys = result.warnings.filter_map { |code| READ_WARNING_KEYS[code] }.uniq.first(4)
            return green_topic? ? "" : t("coverage_limit") if keys.empty?

            keys.map { |key| t("read_warning_#{key}") }.reject { |line| line == omit }.join("\n")
          end

          def append_result_source(answer, source)
            identifier = source["id"]
            return answer unless identifier.is_a?(String) && !identifier.strip.empty?

            answer += "\n#{t("source", source: source_name(identifier, source["label"]))}"
            answer += "\n#{source["url"]}" if safe_url?(source["url"])
            answer
          end

          # Area slugs are internal identifiers and are shown as place names;
          # times keep their own rendering. A bare review date already printed
          # as checked_at is not repeated here.
          def evidence_scope(result)
            shown = checked_dates(result)
            typed_scope_values(result).select { |(_kind, *times)| times.all? { |time| time.is_a?(String) && !time.strip.empty? } }
                                      .reject { |(kind, *times)| kind == :time && shown.include?(times.first.strip) }
                                      .uniq.first(8)
                                      .map { |(kind, *values)| scope_text(kind, values) }
          end

          # Tagged so an area keeps its own rendering all the way through, and
          # so a window keeps its own wording: a start and an end are ONE
          # period. Printed side by side as bare times they read as two event
          # dates, which is how a twelve-hour read window ending after midnight
          # made her state, on 14.09.2026, that something was on 15.9.2026.
          def typed_scope_values(result)
            [result.coverage, result.validity].select { |value| value.is_a?(Hash) }.flat_map do |value|
              times = value.slice("service_day", "origin", "destination", "reviewed_on").values.flatten
              Array(value["area_slugs"]).flatten.map { |slug| [:area, slug] } +
                window_values(value["starts_at"], value["ends_at"]) + times.map { |time| [:time, time] }
            end
          end

          # A lone endpoint is still a period, and saying which end it is costs
          # one word; leaving it bare is the whole defect.
          def window_values(from, through)
            return [[:window, from, through]] if from && through
            return [[:from, from]] if from
            return [[:until, through]] if through

            []
          end

          def scope_text(kind, values)
            case kind
            when :area then place_name(values.first)
            when :window then t("coverage_window", from: human_time(values.first), to: human_time(values.last))
            when :from then t("coverage_from", time: human_time(values.first))
            when :until then t("coverage_until", time: human_time(values.first))
            else human_time(values.first)
            end
          end

          def checked_dates(result)
            checked = result.checked_at
            return [] unless checked.is_a?(Time)

            [checked.getutc.strftime("%Y-%m-%d"), TimeText.local(checked).strftime("%Y-%m-%d")].uniq
          end

          def render_fact(fact)
            answer = item_text(fact)
            name = source_name(fact["source_id"], fact["source_label"])
            answer += "\n#{t("source", source: name)}" if name
            checked = fact["checked_at"]
            answer += "\n#{t("checked_at", time: human_time(checked))}" if checked
            qualifier_lines(fact).each { |line| answer += "\n#{line}" }
            url = fact["source_url"] || fact["destination"]
            answer += "\n#{url}" if safe_url?(url)
            answer
          end

          def compact_water_read?(result, facts)
            result.validity.is_a?(Hash) && result.validity["answer_shape"] == "water_level_v1" &&
              facts.any? && facts.all? { |fact| fact["kind"] == "water_level_observation" }
          end

          def compact_water_text(result, facts)
            shown, hidden = budgeted(facts)
            sections = shown.map do |fact|
              text = item_text(fact)
              text += "\n#{t("fact_observed_at", time: human_time(fact["observed_at"]))}" if fact["observed_at"]
              text
            end
            # Dedupe only identical structured provenance, not arbitrary prose.
            sources = shown.map do |fact|
              [fact["source_id"], fact["source_label"], fact["source_url"], fact["checked_at"] || result.checked_at&.iso8601]
            end.uniq
            sources.each { |id, label, url, checked| sections << compact_provenance(id, label, url, checked) }
            sections << more_items_line(shown, hidden) if hidden.any?
            warnings = rendered_warnings(result)
            sections << warnings unless warnings.empty?
            sections.join("\n\n")
          end

          def public_neighborhood_summary?(result)
            result.coverage.is_a?(Hash) && %w(collected_public_neighborhood_activity area_public_reports public_neighborhood_activities).include?(result.coverage["scope"])
          end

          def compact_service_events?(facts)
            facts.any? && facts.all? do |fact|
              body = fact["notice_body"]
              qualifiers = fact["notice_qualifiers"]
              fact["kind"] == "city_service_event" && fact["answer_shape"] == "service_event_v1" &&
                body.is_a?(String) && !body.strip.empty? && body.length <= 1000 &&
                qualifiers.is_a?(Hash) && qualifiers.size <= 12 &&
                qualifiers.all? { |code, value| code.is_a?(String) && code.match?(/\A[a-z_]{1,80}\z/) && value.is_a?(String) && value.length <= 1000 } &&
                ([body] + qualifiers.values).join(" ") == fact["text"]
            end
          end

          def compact_service_text(result, facts)
            shown, hidden = budgeted(facts)
            parts = [service_event_groups(result, shown)]
            parts << more_items_line(shown, hidden) if hidden.any?
            scope = evidence_scope(result)
            parts << t("coverage", coverage_text: scope.join("; ")) unless scope.empty?
            warnings = rendered_warnings(result)
            parts << warnings unless warnings.empty?
            parts.join("\n\n")
          end

          def service_event_groups(result, facts)
            groups = facts.group_by do |fact|
              coverage = fact["coverage"].is_a?(Hash) ? fact["coverage"] : {}
              [fact["source_id"], fact["source_label"], fact["source_url"], fact["checked_at"] || result.checked_at&.iso8601,
               coverage["requested_relation"], Array(coverage["area_slugs"]).map(&:to_s).sort]
            end
            groups.map do |(id, label, url, checked, *_scope), rows|
              # Only a literal code/text qualifier shared by every notice in
              # this provenance/geographic group can be stated once for all.
              common = rows.map { |fact| fact.fetch("notice_qualifiers").to_a }.reduce { |left, right| left & right }
              parts = []
              parts << t("notice_shared_qualifiers", qualifiers: common.map(&:last).join(" ")) if common.any?
              rows.each do |fact|
                qualifiers = fact.fetch("notice_qualifiers").to_a - common
                body = collapse_restatement(([fact.fetch("notice_body")] + qualifiers.map(&:last)).join(" "))
                qualifier_lines(fact).each { |line| body += "\n#{line}" }
                parts << body
              end
              parts << compact_provenance(id, label, url, checked)
              parts.join("\n\n")
            end.join("\n\n")
          end

          def neighborhood_summary_text(result, facts)
            labels = Array(result.coverage["area_labels"])
            labels = Array(result.coverage["area_slugs"]).map { |slug| place_name(slug) } if labels.empty?
            sections = [t("neighborhood_summary_heading", area: labels.first(4).join(", "))]
            reports = facts.select { |fact| fact["kind"] == "area_public_report" }
            activities = facts.select { |fact| fact["kind"] == "neighborhood_activity" }
            notices = facts - reports - activities
            [[notices, "neighborhood_notices_heading", "notices"], [reports, "neighborhood_reports_heading", "reports"],
             [activities, "neighborhood_activities_heading", "activities"]].each do |rows, key, component_key|
              parts = [t(key)]
              component = result.coverage[component_key]
              if component.is_a?(Hash)
                scope = component.values_at("area_label", "starts_at", "ends_at").select { |value| value.is_a?(String) && !value.empty? }
                parts << t("coverage", coverage_text: scope.map { |value| human_time(value) }.join("; ")) unless scope.empty?
              end
              if component_key == "notices"
                local, uncertain = rows.partition { |fact| !%w(context_only possible_overlap).include?(fact.dig("coverage", "summary_relevance")) }
                parts.concat(summary_rows(result, local))
                parts << t("neighborhood_uncertain_notices_heading") if uncertain.any?
                parts.concat(summary_rows(result, uncertain))
              elsif component_key == "activities"
                parts.concat(summary_rows(result, rows) { |fact| labelled_activity(fact) })
              else
                parts.concat(summary_rows(result, rows))
              end
              sections << parts.join("\n\n") if parts.length > 1
            end
            # Both component coverage limitations matter, even when the other
            # component has facts. Do not truncate them to a generic fallback.
            keys = result.warnings.filter_map { |code| READ_WARNING_KEYS[code] }.uniq
            sections.concat(keys.map { |key| t("read_warning_#{key}") })
            sections << t("coverage_limit") if keys.empty?
            sections.join("\n\n")
          end

          def safe_url?(value)
            return true if self.class.safe_path?(value)
            return false unless value.is_a?(String) && !value.match?(/[\\\s\x00-\x1f]/)

            uri = URI.parse(value)
            uri.scheme == "https" && uri.host && !uri.userinfo
          rescue URI::InvalidURIError
            false
          end

          # The citizen-facing name of an EXTERNAL publisher this read cites,
          # or nil. A refusal names it as the place that holds the record; a
          # local path is one of OUR surfaces and never becomes "check with
          # them", and a read that cites no source at all has no publisher to
          # name.
          def external_source_name(result)
            source = single_source(result)
            url = source["url"]
            return nil unless url.is_a?(String) && safe_url?(url) && !self.class.safe_path?(url)

            name = source_name(source["id"], source["label"])
            name if name.is_a?(String) && !name.strip.empty?
          end

          # The citizen-facing sentence for ONE read warning code, or nil for a
          # code this renderer does not word. Public so a caller promoting a
          # warning to the answer prints the sentence the warning block would
          # have printed — one mapping, one wording, no second copy to drift.
          def warning_sentence(code)
            key = READ_WARNING_KEYS[code]
            key && t("read_warning_#{key}")
          end

          private

          # The turn owns the locale, the clock and the citizen's message; the
          # renderer borrows them.
          def t(key, **values) = @turn.t(key, **values)

          def human_time(value) = @turn.human_time(value)

          def green_topic? = @turn.green_topic?

          def state = @turn.state

          def citizen_text
            message = @turn.respond_to?(:message) ? @turn.message : nil
            return "" if message.nil?

            (message.respond_to?(:text) ? message.text : message).to_s
          end

          # == The fact list

          # One provenance footer per group, never one per item. A single fact
          # keeps exactly the block render_fact has always produced.
          def fact_list_text(facts)
            shown, hidden = budgeted(facts)
            body = shown.length == 1 ? render_fact(shown.first) : grouped_facts_text(shown)
            return body if hidden.empty?

            [body, more_items_line(shown, hidden)].join("\n\n")
          end

          # One citation per group; a per-item link stays with its item, since
          # a link is where THAT notice lives, not who published the group.
          def grouped_facts_text(facts)
            fact_groups(facts).map do |(id, label, checked, *_scope), rows|
              links = rows.map { |fact| fact_url(fact) }.uniq
              shared = links.length == 1 ? links.first : nil
              parts = rows.map { |fact| grouped_fact_body(fact, include_url: shared.nil?) }
              provenance = fact_provenance(id, label, shared, checked)
              parts << provenance unless provenance.empty?
              parts.join("\n\n")
            end.join("\n\n")
          end

          # Source, check time AND geographic scope must match before two
          # items may share one citation.
          def fact_groups(facts)
            facts.group_by do |fact|
              coverage = fact["coverage"].is_a?(Hash) ? fact["coverage"] : {}
              [fact["source_id"], fact["source_label"], fact["checked_at"],
               coverage["requested_relation"], Array(coverage["area_slugs"]).map(&:to_s).sort]
            end
          end

          def fact_url(fact) = fact["source_url"] || fact["destination"]

          # Observation, publication and validity times differ per item even
          # inside one group, so they stay on the item.
          def grouped_fact_body(fact, include_url: false)
            body = item_text(fact)
            qualifier_lines(fact).each { |line| body += "\n#{line}" }
            url = fact_url(fact)
            body += "\n#{url}" if include_url && safe_url?(url)
            body
          end

          def fact_provenance(identifier, label, url, checked)
            lines = []
            name = source_name(identifier, label)
            lines << t("source", source: name) if name
            lines << t("checked_at", time: human_time(checked)) if checked
            lines << url if safe_url?(url)
            lines.join("\n")
          end

          # The compact shapes cite source, URL, then check time; keep their
          # order so a compacted answer does not change shape under grouping.
          def compact_provenance(identifier, label, url, checked)
            block = append_result_source("", { "id" => identifier, "label" => label, "url" => url })
            block += "\n#{t("checked_at", time: human_time(checked))}" if checked
            block.strip
          end

          def summary_rows(result, rows)
            shown, hidden = budgeted(rows)
            parts = if compact_service_events?(shown)
                      [service_event_groups(result, shown)]
                    else
                      shown.map { |fact| render_fact(block_given? ? yield(fact) : fact) }
                    end
            parts << more_items_line(shown, hidden) if hidden.any?
            parts
          end

          def labelled_activity(fact)
            kind = fact.dig("coverage", "activity_type")
            label = t("neighborhood_activity_type_#{kind}") if %w(meeting volunteer public_action community_project).include?(kind)
            label ? fact.merge("text" => "#{label}: #{fact.fetch("text")}") : fact
          end

          # == The budget

          def budgeted(facts)
            limit = budget.items
            return [facts, []] if facts.length <= limit

            ordered = relevance_ordered(facts)
            [ordered.first(limit), ordered.drop(limit)]
          end

          def more_items_line(shown, hidden)
            more_items_text(shown.length, shown.length + hidden.length)
          end

          def more_items_text(shown, total) = t("more_items", shown:, total:)

          # The item the citizen asked about comes first. This is ordering, not
          # routing: the fact set is whatever the read returned, and a question
          # that matches nothing keeps the source's own order.
          #
          # A named measure outranks a topic word, because it is a different
          # kind of match: "vazduha" is shared by every air-quality item, while
          # "pm2" belongs to the one that carries the reading. Scored level with
          # each other, the reading lost a 3-item budget to seven PDF links.
          def relevance_ordered(facts)
            tokens = question_tokens
            return facts if tokens.empty?

            scored = facts.each_with_index.map { |fact, index| [*token_scores(fact, tokens), index, fact] }
            return facts if scored.all? { |_named, score, _index, _fact| score.zero? }

            scored.sort_by { |named, score, index, _fact| [named, score, index] }.map(&:last)
          end

          # Counted negative so an ordinary ascending sort puts the closest
          # match first, and the named measure ahead of the topic word.
          def token_scores(fact, tokens)
            folded = Decidim::Bih::Text.fold(fact["text"].to_s)
            matched = tokens.select { |token| folded.include?(token) }
            [-matched.count { |token| identifying_token?(token) }, -matched.length]
          end

          # Identifiers first, so the cap can never drop the one token that
          # names what was asked about, and the four-character floor can never
          # apply to it.
          def question_tokens
            words = Decidim::Bih::Text.fold(citizen_text).split.uniq
            identifiers, ordinary = words.partition { |word| identifying_token?(word) }
            ordinary = ordinary.reject { |word| word.length < 4 || QUESTION_STOPWORDS.include?(word) }
            (identifiers + ordinary).first(8)
          end

          # A measure or model identifier: a letter run bound to a digit run,
          # which is what folding leaves of "PM2.5" ("pm2 5"), "PM10", "NO2" or
          # "SO2". A bare number is NOT one — it is a year, a price or a house
          # number, and it matches a date in every fact the source ever
          # published. No stopword carries a digit, so the shape is the whole
          # test and the stopword list needs no second consultation here.
          def identifying_token?(word) = IDENTIFYING_TOKEN.match?(word)

          def qualifier_lines(fact)
            present = QUALIFIER_KEYS.select { |key| fact[key] }
            present = prioritised_qualifiers(present) if present.length > budget.qualifiers
            present.map { |key| t("fact_#{key}", time: human_time(fact[key])) }
          end

          def prioritised_qualifiers(keys)
            kept = keys.min_by(budget.qualifiers) { |key| QUALIFIER_PRIORITY.index(key) || QUALIFIER_PRIORITY.length }
            keys.select { |key| kept.include?(key) }
          end

          # == Localisation and identifiers

          def item_text(fact) = collapse_restatement(compact_navigation_text(fact) || fact.fetch("text"))

          # The reader marks optional route-selection guidance separately from
          # the stop/map/caveats. Never infer removable text from sentence order.
          # Reject stale or partial shapes instead of silently losing new advice.
          def compact_navigation_text(fact)
            return unless %w(short brief).include?(level) && fact["kind"] == "transport_navigation"
            return unless fact["source_id"] == "public_transport_stop_registry" && safe_url?(fact["destination"])

            parts = fact["navigation_presentation"]
            return unless valid_navigation_parts?(parts)

            body, optional, ending, caveat = parts.values_at("body", "route_guidance", "ending", "caveat")
            return unless "#{body}#{optional}#{ending}#{caveat}\n#{fact["destination"]}" == fact["text"]

            "#{body}#{ending}#{caveat}\n#{fact["destination"]}"
          end

          def valid_navigation_parts?(parts)
            parts.is_a?(Hash) && parts.keys.sort == %w(body caveat ending route_guidance) &&
              parts.values.all? { |value| value.is_a?(String) && value.length <= 1000 } &&
              !parts["body"].strip.empty? && ["", "."].include?(parts["ending"])
          end

          # The citizen reads a service's name in their own language. The
          # source catalogue's operator-facing label is an inventory entry,
          # not a name; it is the fallback, not the first choice.
          def source_name(identifier, label)
            localized = localized_source_name(identifier)
            return localized if localized
            return label if label.is_a?(String) && !label.strip.empty?

            identifier if identifier.is_a?(String) && !identifier.strip.empty?
          end

          # The catalogue key, with or without the namespace the host wraps it
          # in. A read that carries no facts cites the SOURCE rather than a
          # fact, and the host identifies that source as "source:waste_schedule"
          # (and a single notice as "source:water_service:<digest>") where an
          # event fact carries the bare "waste_schedule". Only the bare form
          # found a name, so the refusal — the one reply that is nothing but a
          # citation — printed the operator-facing inventory label in English
          # inside a Serbian answer: "Izvor: Komunalac regular waste schedule".
          # The second segment IS the catalogue key, so the name it finds is
          # the same name the fact-bearing answer already prints.
          def localized_source_name(identifier)
            candidates = [identifier]
            segments = identifier.to_s.split(":")
            candidates << segments[1] if segments.first == "source" && segments[1]
            candidates.compact.each do |candidate|
              localized = optional_translation("source_name_#{i18n_token(candidate)}")
              return localized if localized
            end
            nil
          end

          def i18n_token(value) = value.to_s.downcase.gsub(/[^a-z0-9_]+/, "_")

          def optional_translation(key, **values)
            return unless I18n.exists?("decidim.bih.dialogue.#{key}", state.fetch("locale"))

            t(key, **values)
          rescue I18n::ArgumentError, KeyError
            nil
          end

          # "mz-dasnica" is an internal identifier; a citizen reads a place.
          # The area-kind prefixes reuse the catalogue's own wording, so the
          # name comes out spelled and localized the way every other surface
          # spells it.
          def place_name(value)
            text = value.to_s.strip
            return text unless text.match?(SLUG)

            kind, _, rest = text.partition("-")
            name = in_reply_script(rest.split(/[-_]/).map(&:capitalize).join(" "))
            if AREA_KIND_PREFIXES.include?(kind) && !name.empty?
              localized = optional_translation("catalog_area_#{kind}", name:)
              return localized if localized
            end

            in_reply_script(text.split(/[-_]/).map { |part| AREA_KIND_ABBREVIATIONS.fetch(part) { part.capitalize } }.join(" "))
          end

          # A slug is always ASCII Latin. A Cyrillic reply that quotes one
          # comes out half in one script and half in the other, so the place
          # name follows the reply.
          def in_reply_script(text)
            Decidim::Bih::Transliterator.localize(text, locale: state.fetch("locale"))
          end

          # A source that publishes a truncated teaser and then the full
          # notice makes the reply say the same sentence twice. The repeated
          # span is removed only where it is repeated verbatim immediately
          # afterwards, so no price, negation or URL can be lost by it.
          def collapse_restatement(text)
            return text unless text.is_a?(String) && text.length >= MIN_RESTATEMENT * 2

            restatement_splits(text).each do |(opening, closing)|
              left = text[0...opening]
              right = text[closing..]
              overlap = repeated_span(left, right)
              next unless overlap

              heading = text[0...(opening - overlap)]
              next unless heading.strip.empty? || (heading.length <= MAX_RESTATEMENT_HEADING && heading.match?(/[:\n]\s*\z/))

              return "#{heading}#{right}"
            end
            text
          end

          def repeated_span(left, right)
            overlap = [left.length, right.length].min
            while overlap >= MIN_RESTATEMENT
              return overlap if right.start_with?(left[-overlap..])

              overlap -= 1
            end
            nil
          end

          # The separator itself is not part of either side: a suffix of the
          # teaser can only match the notice that follows once the ": " or the
          # newline between them is out of the way.
          def restatement_splits(text)
            splits = []
            text.scan(/(?:: |\n)/) { splits << [Regexp.last_match.begin(0), Regexp.last_match.end(0)] }
            splits.first(8)
          end

          # == The presentation operation behind "kraće"

          def finish_shortened(kept, dropped, blocks, carried)
            text = kept.join("\n\n")
            shown = kept.count { |block| !provenance_block?(block) }
            total = carried || (shown + dropped.length)
            if total > shown
              text += "\n\n#{more_items_text(shown, total)}"
              # A URL never disappears with the item it belonged to.
              rescued = dropped_urls(dropped).reject { |url| text.include?(url) }.first
              text += "\n#{rescued}" if rescued
            end
            original = blocks.join("\n\n")
            text.length < original.length ? text : original
          end

          # The "shown/total" line this answer already carries, if any.
          def carried_total(block)
            prefix = more_items_prefix
            return if prefix.empty?

            block.strip[/\A#{Regexp.escape(prefix)}\d+\D{1,16}?(\d+)/, 1]&.to_i
          end

          # more_items has two placeholders, so it needs both markers before
          # its leading literal can be read off the translation.
          def more_items_prefix
            @more_items_prefix ||= t("more_items", shown: MARKER, total: MARKER).to_s.split(MARKER).first.to_s
          rescue StandardError
            ""
          end

          def dropped_urls(dropped)
            dropped.flat_map { |block| block.split("\n") }.map(&:strip).select { |line| safe_url?(line) }
          end

          def trimmed_block(block, target)
            lines = block.split("\n")
            qualifiers = lines.select { |line| qualifier_line?(line) }
            keep_qualifiers = prioritised_lines(qualifiers, target.qualifiers)
            trimmed = lines.each_with_object([]) do |line, kept|
              next kept << line if provenance_line?(line)
              next kept << line if keep_qualifiers.include?(line)
              next if qualifier_line?(line)

              kept << (target.sentences ? essential_sentences(line, target.sentences) : line)
            end
            trimmed.reject { |line| line.to_s.strip.empty? }.join("\n")
          end

          # The opening sentences, plus every later sentence that carries
          # something a citizen acts on. A negation, a price, consent or an
          # emergency instruction is never the part that goes.
          def essential_sentences(line, limit)
            parts = sentences(line)
            return line if parts.length <= limit

            parts.each_with_index
                 .select { |sentence, index| index < limit || essential_sentence?(sentence) }
                 .map(&:first).join(" ")
          end

          # "MI! majica: …" is one sentence. A boundary needs a capital or a
          # digit after it, and a fragment shorter than a phrase belongs to
          # what follows it — otherwise a brand name becomes "the sentence"
          # and the price after it becomes droppable.
          def sentences(line)
            line.split(/(?<=[.!?])\s+(?=[\p{Lu}\p{Nd}])/).each_with_object([]) do |part, out|
              if out.any? && out.last.length < MIN_SENTENCE
                out[-1] = "#{out.last} #{part}"
              else
                out << part
              end
            end
          end

          def prioritised_lines(lines, limit)
            return lines if lines.length <= limit

            ordered = lines.sort_by { |line| QUALIFIER_PRIORITY.index(qualifier_key(line)) || QUALIFIER_PRIORITY.length }
            ordered.first(limit)
          end

          def provenance_block?(block)
            lines = block.split("\n").reject { |line| line.strip.empty? }
            lines.any? && lines.all? { |line| provenance_line?(line) }
          end

          def cites_a_source?(answer)
            prefix = marker_prefix("source", :source)
            !prefix.empty? && answer.to_s.include?(prefix)
          end

          def provenance_line?(line)
            stripped = line.to_s.strip
            return true if safe_url?(stripped)

            [marker_prefix("source", :source), marker_prefix("checked_at", :time)]
              .any? { |prefix| !prefix.empty? && stripped.start_with?(prefix) }
          end

          def qualifier_line?(line) = !qualifier_key(line).nil?

          def qualifier_key(line)
            stripped = line.to_s.strip
            QUALIFIER_KEYS.find do |key|
              prefix = marker_prefix("fact_#{key}", :time)
              !prefix.empty? && stripped.start_with?(prefix)
            end
          end

          def marker_prefix(key, placeholder)
            @marker_prefixes ||= {}
            @marker_prefixes[key] ||= t(key, **{ placeholder => MARKER }).to_s.split(MARKER).first.to_s
          rescue StandardError
            ""
          end

          # Block level: a whole item is exempt from the item budget only for
          # consent text or an emergency instruction. A price is NOT a block
          # exemption — if it were, a price list could never be shortened —
          # but it is a sentence exemption, so a kept item never loses one.
          def safety_block?(text)
            folded = Decidim::Bih::Text.fold(text)
            return true if SAFETY_STEMS.any? { |stem| folded.match?(/(?:\A|\s)#{stem}/) }

            EMERGENCY_NUMBERS.any? { |number| folded.match?(/(?:\A|\s)#{number}(?:\s|\z)/) }
          end

          # Sentence level: safety and consent, plus every price and negation.
          def essential_sentence?(text)
            value = text.to_s
            return true if value.match?(AMOUNT) || safety_block?(value)
            return true if value.lines.any? { |line| safe_url?(line.strip) }

            folded = Decidim::Bih::Text.fold(value)
            NEGATIONS.any? { |word| folded.match?(/(?:\A|\s)#{word}(?:\s|\z)/) }
          end
        end
      end
    end
  end
end

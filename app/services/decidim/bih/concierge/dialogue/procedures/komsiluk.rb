# frozen_string_literal: true

require_relative "../../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        module Procedures
          module Komsiluk
            BOARD = /\b(?:objav\w*|tabl\w*|ploc\w*|posts?|board|clanov\w*|members?)\b/
            PUBLIC_REPORTS = /\b(?:prijav[aeu]|prijavama|problem\w*|public reports?)\b/
            SERVICES = /\b(?:servisn\w*|uslug\w*|services?|utility|utilities)\b/
            ACTIVITY = /\b(?:sta (?:se (?:desava|dogadja)|ima)|what (?:is happening|s happening)|dogadjaj\w*|events?|activity|aktivnost\w*|sastan\w*|okupljan\w*|volont\w*|projek\w*|meetings?|volunteer\w*|projects?)\b/
            OWN_AREA = /\b(?:koji|kojem|which|what)\b.*\b(?:komsilu\w*|kosilu\w*|neighbou?rhood)\b/
            PUBLIC_CHOICES = [
              "servisne informacije", "javne servisne informacije", "servisna obavjestenja", "javna servisna obavjestenja",
              "obavjestenja o uslugama", "javna obavjestenja o uslugama", "obavijesti o uslugama", "javne obavijesti o uslugama",
              "service notices", "public service notices", "utility notices", "javne prijave problema", "prijave problema", "public problem reports"
            ].freeze
            CHOICE_KINDS = %w(mz komsiluk).freeze
            CHOICE_LIMIT = 4
            SAFE_LABEL = /\A[\p{L}\p{M}\d .,'’()\-]+\z/u
            # Internal registry markers and duplicated kind prefixes never reach
            # the citizen: "Janja (prijedlog)" and "MZ Janja" both read as "Janja".
            PROPOSAL_MARKER = /\s*(?:\((?:prijedlog|predlog|приједлог|предлог)\)|(?:prijedlog|приједлог|predlog|предлог))\s*\z/i
            KIND_PREFIX = {
              "mz" => /\A(?:MZ|МЗ|mjesna zajednica|mesna zajednica|мјесна заједница|месна заједница)\s+(?=\S)/i,
              "komsiluk" => /\A(?:Komšiluk|Komsiluk|Комшилук|Neighborhood)\s+(?=\S)/i
            }.freeze

            def self.call(turn)
              return turn.finish(turn.t("board_handoff", url: turn.destination("neighborhood")), resolution: "handoff", offered: true) if turn.action == "neighborhood_post"

              return public_services(turn) if turn.public_activity_refinement?

              query = Text.fold(turn.message.respond_to?(:text) ? turn.message.text : turn.message)
              kind = requested_kind(query)
              return turn.render_read(turn.read(action: "neighborhood_information", topic: "neighborhood")) if kind == :board
              return turn.clarify("query", "neighborhood_activity_choice") if kind == :ambiguous
              return public_reports(turn) if kind == :reports

              if kind == :services || ACTIVITY.match?(query)
                # Both actions are read-only. An explicit public choice must
                # survive a later area answer even if the model kept "board".
                turn.state["active_task"] = "ask_information"
                preserve_public_query(turn)
                return public_services(turn)
              end

              if turn.action == "choose_area" || OWN_AREA.match?(query)
                # Public discovery may use a trusted assigned profile when no
                # location was supplied. It never grants board membership.
                return turn.render_read(turn.read(action: "choose_area", topic: "neighborhood"))
              end

              return public_services(turn) if turn.action == "ask_information" && %w(area_query time_expression).include?(turn.state["pending_slot"])

              if turn.action == "ask_information" || turn.state["pending_slot"] == "query"
                # A vague activity question, including a short area follow-up,
                # is not evidence that the citizen asked for private posts.
                return turn.clarify("query", "neighborhood_activity_choice")
              end

              turn.render_read(turn.read(action: "neighborhood_information", topic: "neighborhood"))
            end

            def self.requested_kind(query)
              kinds = []
              kinds << :board if BOARD.match?(query)
              kinds << :reports if PUBLIC_REPORTS.match?(query)
              kinds << :services if SERVICES.match?(query)
              negated = query.match?(/\b(?:ne (?:zelim|trazim|objav\w*|tabl\w*)|nemoj|not (?:posts?|board)|dont (?:want|show))\b/)
              return :ambiguous if kinds.length > 1 || (kinds.any? && negated)

              kinds.first
            end

            def self.public_choice?(text)
              text.length <= 160 && PUBLIC_CHOICES.include?(Text.fold(text))
            end

            # Display labels for a "which area did you mean" clarification. A
            # komšiluk and an MZ sharing a name are one choice ("komšiluk Janja
            # ili mjesna zajednica Janja"); the identity of each typed candidate
            # is untouched — this only renders.
            def self.choice_labels(candidates, locale: "sr")
              areas = choice_areas(candidates).filter_map { |kind, label| choice_area(kind, label) }.uniq
              areas.group_by { |_, name| Text.fold(name) }.values.map { |group| choice_label(group, locale) }
            end

            # The joined choices for +supplied_area_choice+, or nil when fewer
            # than two areas can be shown (the caller then asks plainly).
            def self.choices_text(candidates, locale: "sr")
              return if choice_areas(candidates).length < 2

              labels = choice_labels(candidates, locale:)
              labels.join(", ") unless labels.empty?
            end

            def self.choice_areas(candidates)
              Array(candidates).first(CHOICE_LIMIT).filter_map do |candidate|
                next unless candidate.is_a?(Hash)

                kind = candidate["area_kind"] || candidate["kind"]
                [kind, candidate["text"] || candidate["label"]] if CHOICE_KINDS.include?(kind)
              end
            end

            def self.choice_area(kind, label)
              return unless label.is_a?(String)

              name = label.strip.sub(KIND_PREFIX.fetch(kind), "").sub(PROPOSAL_MARKER, "").strip
              [kind, name] if name.length.between?(1, 160) && name.match?(SAFE_LABEL)
            end

            def self.choice_label(group, locale)
              names = group.to_h
              if names.has_key?("komsiluk") && names.has_key?("mz")
                I18n.t("decidim.bih.dialogue.area_choice_pair", locale:, komsiluk: names.fetch("komsiluk"), mz: names.fetch("mz"))
              else
                I18n.t("decidim.bih.dialogue.catalog_area_#{group.first.first}", locale:, name: group.first.last)
              end
            end

            def self.area_answer(text)
              return unless text.length <= 160 && text.match?(/\A[\p{L}\p{M}][\p{L}\p{M}'’\-]*(?: +[\p{L}\p{M}][\p{L}\p{M}'’\-]*){0,3}[.!]?\z/u)

              query = Text.fold(text)
              return if requested_kind(query) || ACTIVITY.match?(query)
              return if query.match?(/\b(?:da|ne|necu|nemoj|pomoc|prijavi|parking|autobus|voda|struja|grijanje|otpad|registracija|nalog|yes|no|help|cancel)\b/)

              text.sub(/[.!]\z/, "")
            end

            def self.public_reports(turn)
              turn.state["active_task"] = "ask_information"
              preserve_public_query(turn)
              turn.render_read(turn.read(action: "ask_information", topic: "neighborhood"))
            end

            def self.preserve_public_query(turn)
              raw = turn.message.respond_to?(:text) ? turn.message.text : turn.message.to_s
              turn.state["entities"]["query"] = raw[0, 160]
              turn.state["entity_provenance"]["query"] = "citizen"
            end

            def self.public_services(turn)
              result = turn.read(action: "ask_information", topic: "neighborhood")
              if result.status == "empty" && result.warnings.include?("no_matching_collected_notices") && result.coverage&.fetch("scope", nil) != "collected_public_neighborhood_activity"
                return turn.finish(turn.t("neighborhood_no_notices"), resolution: "answered")
              end

              turn.render_read(result)
            end
          end
        end
      end
    end
  end
end

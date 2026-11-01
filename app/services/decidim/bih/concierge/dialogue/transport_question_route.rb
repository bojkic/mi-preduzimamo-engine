# frozen_string_literal: true

require_relative "deterministic_routes"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Select the public transport reader for explicit stop questions. The
        # reader still owns location, route, calendar and accessibility facts.
        module TransportQuestionRoute
          QUESTION = /\A(?:a\s+)?(?:gdje|gde|kako|koje|koji|treba\s+mi|zelim|where|how|which|i\s+need)\b/
          NEAREST = /\b(?:najbliz\w*|nearest|closest)\s+(?:autobusk\w*\s+)?stajal\w*\b|
            \b(?:najbliz\w*)\s+autobusk\w*\s+stanic\w*\b|\b(?:nearest|closest)\s+bus\s+stop\b/x
          ACCESS = /\A(?:a\s+)?(?:jesu\s+li|je\s+li|da\s+li\s+(?:je|su)|are|is)\s+(?:g\d+\s+)?
            (?:autobus\w*|stajal\w*|buses|bus|bus\s+stops)(?:\s+g\d+)?\s+(?:sigurno\s+)?
            (?:prilagodjen\w*\s+kolic\w*|pristupac\w*|(?:wheelchair\s+)?accessible)\z/x
          OTHER_TASK = /\b(?:prijav\w*|posalji|poslji|objav\w*|registr\w*|nalog|lozink\w*|bodov\w*|poen\w*|
            report|submit|publish|account|password|points|nego|instead|ali|but)\b/x

          NAVIGATION_INSTRUCTION = /\A(?:na\s+(?:whatsappu|viberu|messengeru)\s+)?(?:mi\s+)?
            (?:posalji|napisi|daj)(?:\s+mi)?\s+uputstv\w*\s+(?:za\s+dolazak\s+)?do\s+
            (?:autobusk\w*\s+)?(?:stanic\w*|stajal\w*)(?:\s+(?<stop>[a-z0-9 -]{1,60}))?\z/x

          WALKING_INSTRUCTION = /\A(?:hvala[ ])?(?:
            kako[ ](?:(?:da|mogu)[ ])?(?:dodjem|dodem|stignem|stici)[ ](?:pjeske|peske|pjesice|pesice)|
            mozes[ ]li[ ](?:mi[ ])?(?:napisati|dati)[ ](?:pjesacko[ ]|pesacko[ ])?uputstvo
          )[ ]do[ ](?:autobuske[ ]stanice|autobuskog[ ]stajalista|autobuske|stajalista)(?:[ ](?<stop>[a-z0-9 -]{1,60}))?\z/x
          LOCATION_HINT = /\A(?:moja[ ]priblizna[ ]lokacija[ ]je[ ](?<place>[a-z0-9 -]{2,60})|
            gps[ ]nije[ ](?:dostupan|dostupan[ ]u[ ]ovoj[ ]poruci)|mogu[ ]napisati[ ]ulicu[ ]i[ ]orijentir)\z/x
          TRANSFER_CLOCKS = /\A(?:(?:ako|recimo[ ]da)[ ])?prvi(?:[ ]autobus)?[ ](?:stize|dolazi|stigne)[ ]u[ ](?<ah>\d{1,2})[ ](?<am>\d{2})[ ](?:a[ ])?drugi(?:[ ]autobus)?[ ]
            (?:ide|polazi|odlazi|krece)[ ]u[ ](?<dh>\d{1,2})[ ](?<dm>\d{2})[ ](?:stizem[ ]li|mogu[ ]li[ ](?:stici|presjesti|presesti))\z/x

          module_function

          def transfer_explanation?(query)
            query.length <= 180 &&
              /\A(?:molim[ ])?(?:objasni|pojasni|reci[ ]mi|zasto)\b/.match?(query) &&
              /\b(?:bez[ ](?:izmisljanja|pretpostavljanja)|(?:nemoj|ne)[ ](?:izmisljati|pretpostavljaj|pretpostaviti))\b/.match?(query) &&
              /\b(?:rezervn\w*|drug\w*|alternativn\w*)[ ](?:pola[sz]\w*|autobus\w*|linij\w*)\b/.match?(query) &&
              !OTHER_TASK.match?(query)
          end

          def navigation_instruction?(text)
            query = Text.fold(text.to_s)
            NAVIGATION_INSTRUCTION.match?(query) || WALKING_INSTRUCTION.match?(query)
          end

          def navigation_stop_answer(text, state)
            return unless state.values_at("active_task", "topic", "pending_slot") == %w(ask_information transport stop)
            return unless state.fetch("entities", {})["category"] == "stop_navigation" && !state["draft"]

            query = Text.fold(text.to_s)
            return unless query.match?(/\A[a-z0-9]+(?:[ -][a-z0-9]+){0,4}\z/)
            return if query.match?(/\b(?:ne|da|hvala|sta|kako|koji|gdje|kada|posalji|prijavi|registruj|obrisi|nalog|sutra|danas|otkazi)\b/)

            text.to_s.strip
          end

          def journey_switch?(text)
            query = Text.fold(text.to_s)
            !navigation_instruction?(text) && query.match?(/\b(?:iz|od|sa|from)\b.+\b(?:do|za|to)\b|red\s+voznje|polasc\w*|kalendar\w*|linij\w*/)
          end

          def navigation_follow_up?(text, state)
            return false unless state.values_at("active_task", "topic") == %w(ask_information transport)
            return false unless state.fetch("entities", {})["category"] == "stop_navigation"
            return false if state["draft"]

            /\Ane\s+salji\s+poruku\s+samo\s+mi\s+(?:ovdje|ovde)\s+napisi\s+uputstvo\z/.match?(Text.fold(text.to_s))
          end

          # General travel reasoning, explicitly conditional on the times in
          # the question. This never asserts that either service actually runs.
          def conceptual_request(text, state: nil)
            query = Text.fold(text.to_s)
            active = state && state.values_at("active_task", "topic") == %w(ask_information transport) && !state["draft"]
            if active && transfer_explanation?(query)
              query = Text.fold(state.fetch("entities", {})["query"].to_s)
            end
            if (clock = TRANSFER_CLOCKS.match(query))
              ah, am, dh, dm = clock.values_at(:ah, :am, :dh, :dm).map(&:to_i)
              return unless [ah, dh].all? { |hour| hour.between?(0, 23) } && [am, dm].all? { |minute| minute.between?(0, 59) }

              minutes = (dh * 60 + dm) - (ah * 60 + am)
              key = minutes < 0 ? "transport_transfer_missed" : "transport_transfer_gap"
              return { key:, values: { arrival: format("%02d:%02d", ah, am), departure: format("%02d:%02d", dh, dm), minutes: } }
            end
            return if /\b(?:nalog|lozink\w*|prijav\w*|objav\w*|bodov\w*)\b/.match?(query)
            question = /\A(?:(?:a|i|molim)[ ])?(?:mogu[ ]li|da[ ]li|je[ ]li|znaci[ ]li|kako|sta|objasni|ne[ ]znas|ako)\b/.match?(query)
            crossing = /\b(?:stajalist\w*|prelaz|prelazak)\b/.match?(query) &&
                       /\b(?:preko[ ]puta|druge[ ]strane[ ]ulice|provjeren\w*|proveren\w*)\b/.match?(query)
            if question && crossing && (/\b(?:presje\w*|presed\w*)\b/.match?(query) || active)
              return { key: "transport_crossing_unknown", values: {} }
            end
            distance = /\b(?:vazdusn\w*|zracn\w*|prav\w*[ ]linij\w*)\b/.match?(query) &&
                       /\b(?:hodanj\w*|pjesac\w*|pesac\w*|pjeske|peske)\b/.match?(query) &&
                       /\b(?:znaci|isto|ista|jednak\w*|duzin\w*|razlik\w*)\b/.match?(query)
            return { key: "transport_distance_not_walk", values: {} } if question && distance

            absent_evidence = /\b(?:nema[ ](?:potvrde|podat\w*)|nemas[ ]podat\w*|nepotvrdjen\w*|nije[ ]potvrdjen\w*)\b/.match?(query)
            service_claim = /\b(?:autobus\w*|prevoz\w*|prijevoz\w*|polazak|polas\w*|kalendar\w*)\b/.match?(query)
            correction = /\b(?:ne[ ]znaci|nije[ ]isto|nije[ ]dokaz|ne[ ]pretpostavljaj|nemoj[ ]pretpostaviti)\b/.match?(query)
            if absent_evidence && service_claim && correction
              return { key: "transport_absence_not_service", values: {} }
            end
            if active && LOCATION_HINT.match?(query) && !LOCATION_HINT.match(query)[:place]
              return { key: "transport_location_optional", values: {} }
            end
            nil
          end

          def match(query, text)
            if conceptual_request(text)
              return { action: "ask_information", topic: "transport", entities: { "query" => text } }
            end
            navigation = NAVIGATION_INSTRUCTION.match(query) || WALKING_INSTRUCTION.match(query)
            if navigation && !/\b(?:nalog|registr\w*|lozink\w*|prijav\w*|objav\w*|obris\w*)\b/.match?(query)
              entities = { "query" => text, "category" => "stop_navigation" }
              entities["stop"] = navigation[:stop] if navigation[:stop]
              return { action: "ask_information", topic: "transport", entities: }
            end
            return if OTHER_TASK.match?(query)
            timetable = /\A(?:[gp]\s*\d{1,2}\b|(?:koji|koje|kada|kad)[ ]autobus\w*[ ](?:ide|polazi|vozi)\b)/.match?(query)
            return unless timetable || (QUESTION.match?(query) && NEAREST.match?(query)) || ACCESS.match?(query)

            { action: "ask_information", topic: "transport", entities: { "query" => text } }
          end
        end

        # Keep the broad points-explainer fallback last; existing routes retain their order.
        DeterministicRoutes.register("public_transport_question", before: "points_explainer") do |query, text|
          TransportQuestionRoute.match(query, text)
        end
      end
    end
  end
end

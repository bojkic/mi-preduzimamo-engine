# frozen_string_literal: true

require_relative "answer_context"
require_relative "public_information"
require_relative "civic_question"
require_relative "question_facet"
require_relative "text_predicates"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # THE follow-up owns the turn.
        #
        # A second message with no entity of its own ("A kad se završava
        # trka?") used to be classified from scratch, and the broadest matcher
        # in the chain won — in the rated corpus, the rewards catalogue, five
        # times out of six. This resolves such a turn against what the previous
        # turn actually ANSWERED (+AnswerContext+) instead.
        #
        # == Three moves, in this order, and nothing else
        #
        #   1. STRIP THE ACKNOWLEDGEMENT. "Dobro, a ko trenutno vodi?" is the
        #      standings question with "Dobro," in front of it; the standings
        #      route matches "a ko trenutno vodi?" and always did.
        #   2. RE-ANCHOR. Put the citizen's own earlier question back in front
        #      of this one and run the SAME deterministic chain over the pair.
        #      "Šta je trka komšiluka? A kad se završava trka?" selects the
        #      reviewed race card, which is where the end date lives.
        #   3. CARRY THE SUBJECT. When no reviewed card and no deterministic
        #      route recognises the pair, re-ask the RETAINED read with the
        #      re-anchored question, so the reader is handed a question instead
        #      of two words of ellipsis.
        #
        # == Why this cannot quietly take over the dialogue
        #
        # It is a pure function, it makes no model call and it never writes.
        # Above all it is CONSERVATIVE BY CONSTRUCTION: it declines unless the
        # cold chain found nothing (an explicit new subject always wins), and
        # moves 1 and 2 only ever return what a reviewed card or a registered
        # deterministic route already says about the re-anchored text. Move 3
        # is the only one that proposes anything of its own, and it is fenced
        # five ways — a retained READ (never a card), a retained facet, a
        # follow-up that names no facet of its own, a follow-up short enough to
        # be an ellipsis rather than a subject, and no location slot in the
        # entity bag. That last fence is what keeps "a kabasti?" after a
        # street-bearing waste answer exactly where it is today: the reader
        # already has the citizen's street, so their words ARE the question.
        #
        # Safety, credentials, allegations, courtesy and cancellation are all
        # decided before any of this runs (Coordinator#call and the pre-model
        # stage order), so they keep precedence by construction.
        module AnswerContinuation
          MAX_QUERY = 160
          # Move 3 only. A follow-up with room to name its own subject is not
          # an ellipsis refining the retained one: "A šta ako još nemam nalog?"
          # after a fare answer is an account question, and carrying the fare
          # question into it would answer neither.
          MAX_CARRIED_WORDS = 5
          LOCATION_SLOTS = %w(area_query area_slug street address).freeze
          # The retained kinds THIS module can continue, deliberately narrower
          # than +AnswerContext::KINDS+. A report-guidance card is retained so
          # a brevity request has a subject to land on (CardPresentationStage),
          # and nothing here knows how to continue one: its name is not in
          # PublicInformation's registry, and move 3 has no facet to carry. An
          # unhandled kind admitted here would instead re-anchor the follow-up
          # and hand it to whatever public card or civic read the MERGED text
          # happened to match — a new subject invented out of two questions.
          CONTINUABLE_KINDS = %w(public_card core_read legacy_read).freeze
          # Every question is made of these; sharing one says nothing about
          # sharing a subject.
          INTERROGATIVES = %w(koji koja koje kojem kojoj kada kako gdje gde koliko sada trenutno zasto sta sto
                              molim mozes mozete moze mogu treba jesam jeste what when where which how much many
                              does about please).freeze

          # Exactly one of the two is set.
          Continuation = Data.define(:card, :read) do
            def card? = !card.nil?
          end

          module_function

          # A Continuation, or nil when this turn is not a follow-up we can
          # resolve. +follow_up+ is set by a caller that has ALREADY established
          # the turn is a follow-up by other means (a contrastive correction
          # carries its own proof), which waives the ellipsis shape but no
          # other guard.
          def resolve(text:, state:, follow_up: false)
            retained = retained_context(state)
            return if retained.nil?
            return unless usable?(text)
            # An explicit new subject keeps precedence: when the cold chain
            # already answers this turn, there is nothing to continue.
            return if PublicInformation.card(text) || CivicQuestion.classify(text)

            resolve_retained(text:, state:, retained:, follow_up:)
          end

          def resolve_retained(text:, state:, retained:, follow_up:)
            stripped = TextPredicates.strip_leading_filler(text)
            folded = Text.fold(stripped)
            if retained["kind"] == "public_card" && !state["draft"]
              if %w(civic_vote_integrity civic_vote_without_points).include?(retained["subject"]) && folded == "samo pravilo me zanima ne stanje naloga"
                return Continuation.new(card: PublicInformation::VOTE_WITHOUT_POINTS, read: nil)
              end
              if %w(race_overview race_prize civic_race_scope).include?(retained["subject"]) && folded == "ne zelim katalog nagrada"
                return Continuation.new(card: PublicInformation::RACE_SCOPE, read: nil)
              end
            end
            return if excluded?(folded)

            feedback = feedback_controls_continuation(retained, state, folded)
            return feedback if feedback
            return repeated(retained) if TextPredicates.repeat_request?(folded)
            return unless follow_up || TextPredicates.ellipsis_follow_up?(folded)

            continued(retained, state, text, stripped, explicit: follow_up)
          end

          # Move 1, then 2, then 3.
          def continued(retained, state, text, stripped, explicit:)
            unstripped = stripped == text.strip
            found = (deterministic(stripped) unless unstripped)
            return found if found

            anchored = anchored_text(retained, stripped)
            found = deterministic(anchored) if anchored
            return found if found && usable_selection?(found, stripped, retained)

            carried(retained, state, stripped, anchored, explicit:)
          end

          # Move 2 merges two questions into one string and runs keyword
          # matchers over the pair, so the ANCHOR's own words can drive the
          # selection on their own. For a READ that is harmless: the reader is
          # handed the merged question and answers the new half of it. For a
          # CARD it is not — the card is fixed copy, and re-selecting the one
          # already given returns the previous answer verbatim to a citizen who
          # asked something else.
          #
          # So a continuation CARD has to be about the retained subject in the
          # citizen's own words: "Šta je trka komšiluka?" then "A kad se
          # završava trka?" shares +trka+ and the race card is the answer, while
          # the same follow-up after a vote-integrity answer shares nothing with
          # it and must not be answered with the vote-integrity card again.
          def usable_selection?(found, stripped, retained)
            return true unless found.card?

            shares_subject?(stripped, retained.fetch("anchor"))
          end

          def shares_subject?(stripped, anchor)
            follow_up = content_tokens(stripped)
            return false if follow_up.empty?

            follow_up.intersect?(content_tokens(anchor))
          end

          # Words that could name a subject: long enough to carry meaning, and
          # not one of the interrogatives every question is made of.
          def content_tokens(text)
            # Not Array#exclude?: these unit tests load the engine without
            # ActiveSupport's core extensions, exactly as FactRenderer does.
            Text.fold(text.to_s).split(/\s+/).select { |token| token.length >= 4 && !INTERROGATIVES.include?(token) } # rubocop:disable Rails/NegateInclude
          end

          # The same answer again, because that is what was asked for.
          def feedback_controls_continuation(retained, state, folded)
            return unless retained["kind"] == "public_card" && retained["subject"].to_s.start_with?("civic_feedback")
            return if state["draft"] || state["pending_slot"] == "description"
            return unless [nil, "ask_information", "help"].include?(state["active_task"])
            return if AnswerContext::PRIVATE_TOPICS.include?(state["topic"])
            card = PublicInformation.feedback_follow_up_card(folded)
            return unless card

            Continuation.new(card:, read: nil)
          end

          def repeated(retained)
            if retained.fetch("kind") == "public_card"
              card = card_named(retained.fetch("subject"))
              return card && Continuation.new(card:, read: nil)
            end
            read_for(retained, retained.fetch("anchor"))
          end

          # Only what a reviewed card or a registered route already says.
          def deterministic(candidate)
            card = PublicInformation.card(candidate)
            return Continuation.new(card:, read: nil) if card

            read = CivicQuestion.classify(candidate)
            Continuation.new(card: nil, read:) if read
          end

          # Move 3. See the fences in the module comment.
          def carried(retained, state, stripped, anchored, explicit:)
            return if anchored.nil?
            return unless retained["facet"]
            # A follow-up that names a facet of its own already has a route for
            # it, and the model plus the runner's own facet handling own that
            # turn. The one exception is a caller that has independent proof
            # this continues the same subject - a contrastive correction says
            # so in the citizen's own words ("Ne pitam za liniju. Pitam koliko
            # košta karta za dijete."), which is stronger than any shape.
            return unless explicit || (QuestionFacet.call(stripped).nil? && brief?(stripped))
            return if located?(state)

            read_for(retained, anchored)
          end

          def brief?(stripped)
            stripped.to_s.split(/\s+/).length <= MAX_CARRIED_WORDS
          end

          def read_for(retained, query)
            action = retained["action"]
            topic = retained["topic"]
            return if action.nil? || topic.nil? || query.to_s.length > MAX_QUERY

            Continuation.new(card: nil, read: { action:, topic:, entities: { "query" => query } })
          end

          # The citizen's earlier question, then this turn's words. Their own
          # wording in both halves: nothing is paraphrased and nothing from the
          # ANSWER is carried, only the question that was asked.
          def anchored_text(retained, stripped)
            anchor = retained["anchor"].to_s.strip
            return if anchor.empty?

            candidate = "#{anchor} #{stripped}".strip
            candidate if candidate.length <= MAX_QUERY
          end

          # A retained read whose question already carried a place leaves the
          # place in the entity bag, and the reader still has it. Re-anchoring
          # such a turn would replace the citizen's new words with the old
          # question. Leave it exactly where it is.
          def located?(state)
            entities = state["entities"]
            return false unless entities.is_a?(Hash)

            LOCATION_SLOTS.any? { |slot| !entities[slot].to_s.strip.empty? }
          end

          def retained_context(state)
            return unless state.is_a?(Hash)

            value = state[AnswerContext::KEY]
            value if value.is_a?(Hash) && CONTINUABLE_KINDS.include?(value["kind"]) && value["anchor"].is_a?(String)
          end

          def usable?(text)
            text.is_a?(String) && text.strip.length.between?(2, 160) && text.match?(/\p{L}/)
          end

          # Moves that mean something else and already have an owner.
          def excluded?(folded)
            TextPredicates.presentation_request?(folded) || TextPredicates.resume_request?(folded) ||
              TextPredicates.local_repair_phrase?(folded) || TextPredicates.english_repair_phrase?(folded) ||
              TextPredicates.queued_question?(folded)
          end

          def card_named(name)
            cards.find { |card| card.name == name }
          end

          # Derived from PublicInformation's own constants, so a card added
          # there is reachable here without a second list to keep in step.
          def cards
            @cards ||= (PublicInformation.constants.map { |name| PublicInformation.const_get(name) } + PublicInformation::FEEDBACK_FACETS.values)
                                        .select { |value| value.is_a?(PublicInformation::Card) }.freeze
          end
        end
      end
    end
  end
end

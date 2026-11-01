# frozen_string_literal: true

require_relative "answer_context"
require_relative "contracts"
require_relative "fact_renderer"
require_relative "state_store"
require_relative "public_information"
require_relative "report_guidance"
require_relative "resolution"
require_relative "text_predicates"
# The seam this file registers into. Circular by design and safe: by the time
# pre_model_stages requires this file back, its module and +register+ exist.
require_relative "pre_model_stages"
require_relative "procedure_runner"
require_relative "../responder"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # "Kraće" after a CARD.
        #
        # == The defect this closes
        #
        # A presentation request is an operation on the answer already given,
        # and the coordinator owns it: +Coordinator#presentation_understanding+
        # turns "kraće" into the SAME task rendered to a tighter budget.
        # It finds that subject through +presentation_subject+, which reads the
        # open task first and the retained +AnswerContext+ second — and a
        # retained CARD has no action/topic to read. It cannot have one:
        # +AnswerContext+ REFUSES a card that carries a read identity, because
        # a card is reviewed copy and not a read. So the turn fell through to
        # the model, was classified from scratch, and came back (case r9c02) as
        # the 957-character Sistem 48 catalogue — longer than the answer the
        # citizen had just asked to shorten.
        #
        # Report cards were worse off still: +ReportGuidanceStage+ retained
        # nothing at all, so there was not even a subject to miss.
        #
        # == What this does instead
        #
        # Re-serves THE SAME CARD's reviewed copy, through the deterministic
        # +shorten_reply+ the coordinator already uses for legacy answers. The
        # copy is fixed and reviewed: nothing here paraphrases it, regenerates
        # it or asks a model to condense it, and +FactRenderer#shorten+ returns
        # the original untouched whenever its budget cannot improve on it.
        # Re-serving the card unchanged is the floor; answering with something
        # ELSE, and longer, is the defect.
        #
        # == Why it is a stage rather than a branch of the coordinator
        #
        # +fast_understanding+ returns an Understanding, and a card is not one:
        # it is an ANSWER, with no action, no topic and no read behind it. A
        # stage is the registered seam for exactly that (PreModelStages), and
        # the coordinator keeps the presentation move for every subject that
        # DOES have a read identity — this stage declines the moment there is
        # an open task, so +presentation_subject+'s first branch always wins.
        #
        # == Where it sits, and why last
        #
        # Registered +after: "procedure_fee_follow_up"+, i.e. after every other
        # stage. Only turns that would otherwise have reached the provider get
        # here, so no existing stage loses a turn it answers today: a cold card
        # selection, a retained-evidence question, a service or fee follow-up
        # all keep precedence. It makes no model call and performs no read.
        module CardPresentation
          # The kinds this module can re-serve: AnswerContext's own card list,
          # so adding a card kind there is a single edit.
          KINDS = AnswerContext::CARD_KINDS

          module_function

          # kind => the registry that owns that kind's card names. Nothing is
          # ever looked up across the two.
          #
          # A METHOD and not a constant, deliberately: these four files load in
          # a require cycle (report_guidance requires pre_model_stages, which
          # requires this file back), so a constant naming +ReportGuidance+ at
          # load time raises NameError whenever report_guidance.rb happens to
          # be the file that opens the cycle — which is exactly what Zeitwerk
          # does the first time production resolves that constant. Resolving
          # inside a method body defers the lookup to call time, when every
          # module is defined. +loads_under_any_entry_point+ pins it.
          def registry(kind)
            case kind
            when "public_card" then PublicInformation
            when "report_card" then ReportGuidance
            end
          end

          # The retained CARD answer, or nil. Reads only what the state store
          # has already normalised — an expired or malformed context is nil by
          # then (StateStore#validate runs AnswerContext.normalize on every
          # read), and the belt-and-braces expiry check below keeps that true
          # for a caller that assembled a state some other way.
          def retained(state, now:)
            return unless state.is_a?(Hash)

            value = state[AnswerContext::KEY]
            return unless value.is_a?(Hash) && KINDS.include?(value["kind"])
            return unless value["subject"].is_a?(String) && value["anchor"].is_a?(String)
            return unless live?(value, now:)

            value
          end

          # The card that kind's own registry names, or nil. A name is only
          # ever resolved against the registry its kind names, so a report
          # card can never be answered with public-information copy.
          def card_for(kind, name)
            return if registry(kind).nil?

            cards(kind).find { |card| card.name == name }
          end

          # The reviewed copy, rendered by the card's own module. Returns nil
          # when this host has no copy for it, exactly as the two answering
          # stages do.
          def answer(kind, card, locale:, brief: false)
            owner = registry(kind)
            return if owner.nil?

            text = kind == "public_card" ? owner.answer(card, locale:, brief:) : owner.answer(card, locale:)
            text unless text.nil? || text.strip.empty?
          rescue StandardError
            nil
          end

          def quick_replies(kind, card, locale:)
            owner = registry(kind)
            return [] unless owner.respond_to?(:quick_replies)

            owner.quick_replies(card, locale:) || []
          rescue StandardError
            []
          end

          # Derived from each registry's own constants, so a card added there
          # is reachable here without a second list to keep in step. Memoised
          # per kind and resolved lazily: these files load in a cycle, and a
          # constant evaluated at load time would read a half-defined module.
          def cards(kind)
            @cards ||= {}
            @cards[kind] ||= begin
              owner = registry(kind)
              type = owner.const_get(:Card)
              values = owner.constants.map { |name| owner.const_get(name) }
              values += owner::FEEDBACK_FACETS.values if kind == "public_card"
              values
                   .select { |value| value.is_a?(type) }.freeze
            end
          end

          def live?(value, now:)
            expires = Float(value["expires_at"])
            expires.finite? && now.to_f < expires
          rescue ArgumentError, TypeError
            false
          end
        end

        module CardPresentationStage
          module_function

          def result_for(turn)
            return if evidence_message?(turn.message)
            return if turn.cancelled?
            return unless presentation_request?(turn)

            retained = CardPresentation.retained(turn.state, now: turn.context.now)
            return if retained.nil?

            kind = retained.fetch("kind")
            card = CardPresentation.card_for(kind, retained.fetch("subject"))
            return if card.nil?

            answered(turn, kind, card, retained)
          end

          # Every guard the coordinator applies to a presentation request
          # BEFORE it decides the subject, applied here in the same order
          # because this stage runs earlier than fast_understanding does.
          # A cancellation is checked by the caller above.
          def presentation_request?(turn)
            text = turn.text
            return false if ProcedureRunner.resume_request?(text, turn.state)
            # The OPEN TASK owns a brevity request when there is one — the
            # first branch of Coordinator#presentation_subject. Declining
            # here is what keeps that branch reachable.
            return false if turn.state["active_task"] && turn.state["topic"]

            TextPredicates.presentation_request?(Decidim::Bih::Text.fold(text))
          end

          def answered(turn, kind, card, retained)
            locale = locale_for(turn)
            level = requested_level(turn)
            text = CardPresentation.answer(kind, card, locale:, brief: %w(short brief).include?(level))
            return if text.nil?

            reply = Responder::Reply.new(
              text: shortened(turn, text, level), report: nil, answer_intent: card.answer_intent,
              tone: "core", locale:, quick_replies: CardPresentation.quick_replies(kind, card, locale:)
            )
            # The SAME subject and the SAME anchor: a brevity request is not a
            # new question, so the citizen's original words stay the anchor and
            # the ten-minute window is refreshed rather than restarted on the
            # word "kraće". Best effort, like every card retention.
            #
            # The LEVEL is retained in the same write, because without it a
            # repeated "kraće" re-served the identical rendering: the level is
            # computed from the level already in force, and nothing had ever
            # recorded one for a card. It rides this best-effort write rather
            # than +turn.accept+ deliberately — a refused CAS must cost the
            # citizen a remembered preference, never the answer they just got.
            state = turn.retain_answer(kind:, subject: card.name, anchor: retained.fetch("anchor"), presentation_level: level, locale:)
            ProcedureRunner::Result.new(state:, reply:, resolution: Resolution::ANSWERED,
                                        fact_ids: [], handoff_offered: false, handoff_completed: false)
          end

          # The brevity level THIS turn renders at: the level already in force
          # (nil on the first request, which reads back as the renderer's
          # default), stepped by whatever this message asks for. "kraće" steps
          # one level; "još kraće" goes straight to the tightest budget; the
          # tightest budget is the floor and re-serving it unchanged is the
          # honest answer, not a defect.
          def requested_level(turn)
            FactRenderer.requested_level(turn.text, current: turn.state[StateStore::PRESENTATION_LEVEL_KEY])
          end

          # The runner's deterministic presentation operation — the one
          # Coordinator#shortened_secondary_reply already applies to a legacy
          # answer. No read, no model call, no paraphrase. It returns the
          # original whenever its budget cannot improve on it, and this never
          # lets a "shortened" answer come back longer than what it shortened.
          def shortened(turn, text, level)
            procedures = turn.procedures
            return text unless procedures.respond_to?(:shorten_reply)

            candidate = procedures.shorten_reply(text, state: turn.state, context: turn.context, message: turn.message, level:).to_s
            return text if candidate.strip.empty? || candidate.length > text.length

            candidate
          rescue StandardError
            text
          end

          # A photo or a pin is evidence for a report, never a presentation
          # request about the previous answer.
          def evidence_message?(message)
            return true if message.respond_to?(:image_url) && !message.image_url.nil?

            message.respond_to?(:latitude) && !message.latitude.nil?
          end

          # The same rule both card stages use: a message written in Cyrillic
          # is answered in Cyrillic, otherwise the saved conversation locale.
          def locale_for(turn)
            requested = TextPredicates.presentation_locale(turn.text)
            return requested if requested
            return "sr-Cyrl" if turn.text.match?(/\p{Cyrillic}/)

            saved = turn.state["locale"]
            Contracts::LOCALES.include?(saved) ? saved : "sr"
          end
        end

        PreModelStages.register("card_presentation", after: "procedure_fee_follow_up") do |turn|
          CardPresentationStage.result_for(turn)
        end
      end
    end
  end
end

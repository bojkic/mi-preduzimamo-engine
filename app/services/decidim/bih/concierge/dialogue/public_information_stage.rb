# frozen_string_literal: true

require_relative "public_information"
require_relative "answer_context"
require_relative "answer_continuation"
require_relative "civic_question"
require_relative "procedure_runner"
require_relative "../responder"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Registers the reviewed public-information cards as a pre-model stage.
        #
        # == Where it sits in the order
        #
        # After "resume_nothing" and before "public_information_follow_up". The
        # position matters twice:
        #
        #   * everything Coordinator#call decides earlier still wins — an
        #     immediate danger, a credential, a legal allegation, a courtesy and
        #     an explicit cancellation are all handled before any stage runs, so
        #     safety keeps precedence over every card by construction;
        #   * it runs BEFORE the retained-source follow-ups, because the rated
        #     corpus shows exactly those follow-ups answering "vrati se na
        #     bodove: da li utiču na glasanje?" with the rewards catalogue.
        #
        # == What it does not do
        #
        # It starts no task. A card is an answer to a question the platform has
        # already decided; it is not a task. Leaving the TASK state untouched is
        # what guarantees that an unfinished report draft, a pending
        # confirmation or a suspended task survives one of these answers exactly
        # as it was — the same contract the built-in "resume_nothing" stage has,
        # and +public_information_test+ pins every one of those fields.
        #
        # What it does now record is WHAT IT ANSWERED, in the separate
        # +AnswerContext+ slot: the card, the citizen's own words for the
        # subject and an expiry. Without it, the next message ("A kad se
        # završava trka?") had nothing to attach to and was re-classified from
        # scratch into the rewards catalogue. The write is best effort — a
        # refused CAS loses the continuity hint and keeps the answer.
        #
        # It makes no model call and performs no read, so every card answers
        # identically with the provider unavailable.
        module PublicInformationStage
          module_function

          # nil when this turn is not a card question, or when the copy a card
          # needs is not configured on this host — in which case the turn simply
          # continues to the stages and the understanding call behind it.
          def result_for(turn)
            return if evidence_message?(turn.message)

            cold = PublicInformation.card(turn.text)
            # A request to shorten the same card belongs to the presentation
            # stage, which preserves its anchor and uses reviewed brief copy.
            # A genuinely different facet still wins as a new current question.
            if cold && TextPredicates.presentation_request?(Decidim::Bih::Text.fold(turn.text))
              retained = AnswerContext.normalize(turn.state[AnswerContext::KEY], now: turn.context.now,
                                                 state_expires_at: turn.state["expires_at"])
              return if retained && retained.values_at("kind", "subject") == ["public_card", cold.name]
            end
            card = cold || continuation_card(turn)
            return if card.nil?
            return if recognised_citizen_identity?(turn, card)

            locale = locale_for(turn)
            text = PublicInformation.answer(card, locale:)
            return if text.nil? || text.strip.empty?

            reply = Responder::Reply.new(
              text:, report: nil, answer_intent: card.answer_intent, tone: "core",
              quick_replies: PublicInformation.quick_replies(card, locale:)
            )
            state = turn.retain_answer(kind: "public_card", subject: card.name, anchor: anchor_for(turn, cold))
            ProcedureRunner::Result.new(state:, reply:, resolution: Resolution::ANSWERED,
                                        fact_ids: [], handoff_offered: false, handoff_completed: false)
          end

          # The card a follow-up to an earlier card is asking for. Declines
          # every turn another stage owns (an evidence question, a
          # cancellation) and every turn the cold selection already answered.
          def continuation_card(turn)
            return if turn.cancelled? || turn.prior_evidence_kind

            AnswerContinuation.resolve(text: turn.text, state: turn.state)&.card
          end

          # A cold card is anchored on the words that selected it. A
          # CONTINUATION keeps the anchor it continued, so a chain of follow-ups
          # stays tied to the question that opened the subject rather than
          # drifting one ellipsis at a time.
          def anchor_for(turn, cold)
            return turn.text if cold

            retained = turn.state[AnswerContext::KEY]
            (retained.is_a?(Hash) && retained["anchor"]) || turn.text
          end

          # "Znaš li ko sam ja?" is two questions wearing one sentence.
          #
          # From a session this conversation holds no actor for, it is the
          # privacy question the card answers truthfully: Milica recognises
          # nobody on her own. From a citizen the channel has already resolved
          # and bound into the trusted scope, it is an OWN-STATE read — and the
          # card's "this conversation does not recognise you by itself" is
          # false to a citizen Milica named by name one turn earlier, which is
          # what production returned on 14.09.2026.
          #
          # The card only STEPS ASIDE here; it never answers instead. The turn
          # continues to the own_state_identity route, and the Responder's own
          # authorized reader (own_state_user — the actor, the organization and
          # the trusted scope, re-checked on this turn) decides what may be
          # said; a scope it cannot stand behind still gets a sign-in answer
          # rather than a name. Nothing here reads an account, and nothing here
          # remembers one: AnswerContext refuses to retain own-state, so the
          # question is re-decided from the live scope every single turn.
          #
          # Only the identity card, and only for an utterance the own-state
          # route itself recognises. "Da li znaš moje ime ako nisam
          # prijavljen?" carries its own condition, is not an own-state
          # question, and keeps the card whoever asks it.
          def recognised_citizen_identity?(turn, card)
            return false unless card == PublicInformation::IDENTITY
            return false unless resolved_actor?(turn.context)

            CivicQuestion.own_state(turn.text) == "identity"
          end

          # The conversation's session state, not an account read: this turn's
          # trusted scope names an actor inside an organization. The engine
          # never treats that as proof of WHO — the own-state path does that —
          # only as proof that there is somebody to ask about.
          def resolved_actor?(context)
            actor = context.respond_to?(:actor_id) ? context.actor_id : nil
            organization = context.respond_to?(:organization_id) ? context.organization_id : nil
            !actor.nil? && !organization.nil?
          end

          # A photo or a pin is evidence for a report, never a policy question.
          def evidence_message?(message)
            return true if message.respond_to?(:image_url) && !message.image_url.nil?

            message.respond_to?(:latitude) && !message.latitude.nil?
          end

          # The saved conversation locale, except that a message written in
          # Cyrillic is always answered in Cyrillic. Same rule the coordinator's
          # own repair path uses, without reaching back into the coordinator.
          def locale_for(turn)
            return "sr-Cyrl" if turn.text.match?(/\p{Cyrillic}/)

            saved = turn.state["locale"]
            Contracts::LOCALES.include?(saved) ? saved : "sr"
          end
        end

        PreModelStages.register("public_information_card", before: "public_information_follow_up") do |turn|
          PublicInformationStage.result_for(turn)
        end
      end
    end
  end
end

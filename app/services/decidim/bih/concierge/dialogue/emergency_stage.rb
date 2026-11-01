# frozen_string_literal: true

require_relative "pre_model_stages"
require_relative "state_store"
require_relative "contracts"
require_relative "procedure_runner"
require_relative "resolution"
require_relative "../emergency_signal"
require_relative "../emergency_card"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # THE first pre-model stage: immediate danger, and the one or two
        # follow-up turns that belong to it.
        #
        # == Precedence
        #
        # It registers +before: "resume_nothing"+, which makes it the first
        # stage the coordinator walks, so a message that reports danger is
        # answered before a retained-evidence follow-up, before a service
        # follow-up, before a report draft continues, and before any
        # understanding or model call. Registration order is the only thing
        # that decides this — see PreModelStages.
        #
        # == Continuity, and its limits
        #
        # The opener writes StateStore::SAFETY_CONTEXT_KEY: the danger kind,
        # the topic it was opened under, when it opened and how many turns it
        # has followed. That is the WHOLE memory — no incident record, no
        # location, no text. The store drops it on expiry, on a topic change,
        # above the turn cap and when the conversation is cleared; this stage
        # additionally stops writing it once the cap is reached.
        #
        # A follow-up must be unambiguous ("koga da zovem?", "koji je broj
        # hitne pomoći?", "djeca su pored toga") — anything else declines and
        # the ordinary pipeline answers, which is what stops a conversation
        # that once mentioned a fire from reading every later question as one.
        #
        # == What it never does
        #
        # No model call, no read port, no effect, no report. The only write is
        # the coordinator's own CAS through +turn.accept+, and if that write
        # fails the card still goes out — a busy or unavailable store must
        # never cost a citizen the emergency answer.
        module EmergencyStage
          NAME = "emergency"
          KEY = StateStore::SAFETY_CONTEXT_KEY
          MAX_TURNS = StateStore::SAFETY_CONTEXT_MAX_TURNS
          TTL = StateStore::SAFETY_CONTEXT_TTL
          ANSWER_INTENT = "safety"

          module_function

          def call(turn)
            text = turn.text
            assessment = EmergencySignal.assess(text)
            return opened(turn, assessment, text) if assessment

            continued(turn, text)
          rescue StandardError => e
            # A failure here must not swallow the turn: decline and let the
            # ordinary pipeline (and the coordinator's own red-zone control
            # reply) answer, exactly as it did before this stage existed.
            Coordinator.record_failure(stage: "emergency", error: e) if defined?(Coordinator)
            nil
          end

          # A fresh emergency: answer with the service for what was reported,
          # and open the bounded context the next turn may use.
          def opened(turn, assessment, text)
            card = EmergencyCard.call(assessment, locale: locale_for(turn, text))
            return nil unless card

            deliver(turn, card, kind: assessment.kind, opened_at: nil, turns: 1)
          end

          # A later turn. It is part of the emergency only if it says so.
          def continued(turn, text)
            context = safety_context(turn)
            follow_up = EmergencySignal.follow_up(text)
            return standalone_service(turn, text) unless context && follow_up

            turns = context.fetch("turns").to_i + 1
            card = follow_up_card(context, follow_up, locale: locale_for(turn, text))
            return clear_context(turn, card) if turns > MAX_TURNS

            deliver(turn, card, kind: context.fetch("kind"), opened_at: context.fetch("opened_at"), turns:)
          end

          # "Koji je broj vatrogasaca?" with no emergency behind it: one
          # reviewed contact, no context opened, nothing remembered.
          def standalone_service(turn, text)
            service = EmergencySignal.service_request(text)
            return nil unless service

            card = EmergencyCard.for_service(service, locale: locale_for(turn, text))
            card ? result(turn, card, state: nil) : nil
          end

          def follow_up_card(context, follow_up, locale:)
            service = follow_up[:service]
            return EmergencyCard.for_service(service, locale:) if service && service != context.fetch("kind")

            EmergencyCard.call(
              EmergencySignal::Assessment.new(kind: context.fetch("kind"), also: nil),
              locale:, people_present: follow_up[:people] == true
            )
          end

          # Answer, then try to save the context. The card is composed before
          # any state work and is returned whatever the store does.
          def deliver(turn, card, kind:, opened_at:, turns:)
            candidate = result(turn, card, state: state_with_context(turn, kind:, opened_at:, turns:))
            accepted = turn.accept(candidate)
            accepted.equal?(candidate) ? accepted : result(turn, card, state: nil)
          rescue StandardError
            result(turn, card, state: nil)
          end

          # The turn cap is reached: answer this one, then forget.
          def clear_context(turn, card)
            now = turn.context.now.to_f
            cleared = renew_optional_location(safety_base_state(turn).merge("updated_at" => now, "expires_at" => now + Contracts::CONTEXT_TTL, KEY => nil), now)
            candidate = result(turn, card, state: cleared)
            accepted = turn.accept(candidate)
            accepted.equal?(candidate) ? accepted : result(turn, card, state: nil)
          rescue StandardError
            result(turn, card, state: nil)
          end

          def state_with_context(turn, kind:, opened_at:, turns:)
            now = turn.context.now.to_f
            # The window is measured from the FIRST card, so a follow-up can
            # never extend an emergency context beyond its ten minutes.
            opened = opened_at ? Float(opened_at) : now
            base = safety_base_state(turn)
            renew_optional_location(base.merge(
              "updated_at" => now,
              "expires_at" => now + Contracts::CONTEXT_TTL,
              KEY => { "kind" => kind, "topic" => base.fetch("topic"), "opened_at" => opened,
                       "expires_at" => opened + TTL, "turns" => turns }
            ), now)
          end

          # A danger turn is still citizen activity. Extend only the metadata
          # deadline of an already encrypted location; never decrypt it here.
          def renew_optional_location(state, now)
            slots = state[ConversationSlots::KEY]
            return state unless slots.is_a?(Hash) && %w(exact address).include?(slots.dig("location", "kind"))

            updated = slots.merge("location" => slots.fetch("location").merge("expires_at" => now + Contracts::CONTEXT_TTL))
            state.merge(ConversationSlots::KEY => updated)
          end

          # Cancellation still clears every prior task, draft and queue even
          # when the emergency stage answers before ProcedureRunner#cancel.
          # Keep the same CAS/version and conversation-clock fields as cancel.
          def safety_base_state(turn)
            return turn.state unless turn.cancelled?

            StateStore.new.empty_state(turn.context).merge(turn.state.slice("version", "created_at", "locale"))
          end

          def safety_context(turn)
            value = turn.state[KEY]
            value.is_a?(Hash) && value["kind"].is_a?(String) ? value : nil
          end

          # The conversation's own locale is the fallback; the script of THIS
          # message wins, because that is what the citizen is reading in.
          def locale_for(turn, text)
            EmergencyCard.locale_for(text, fallback: turn.state["locale"])
          end

          def result(_turn, card, state:)
            reply = Responder::Reply.new(text: card, report: nil, quick_replies: [], answer_intent: ANSWER_INTENT, tone: "core")
            # A cancellation that also reports danger is answered as danger.
            # Guidance is distinct from incident resolution and dispatch,
            # including a danger statement combined with cancellation.
            resolution = Resolution::SAFETY_GUIDANCE
            ProcedureRunner::Result.new(state:, reply:, resolution:, fact_ids: [], handoff_offered: false, handoff_completed: false)
          end
        end

        PreModelStages.register(EmergencyStage::NAME, before: "resume_nothing") do |turn|
          EmergencyStage.call(turn)
        end
      end
    end
  end
end

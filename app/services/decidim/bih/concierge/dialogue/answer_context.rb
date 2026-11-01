# frozen_string_literal: true

require_relative "contracts"
require_relative "text_predicates"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # WHAT the citizen was last told, kept deliberately apart from WHAT the
        # citizen is doing.
        #
        # == Why a second, separate record
        #
        # +PublicInformationStage+ answers a reviewed card and writes NO task
        # state, on purpose: a card is an answer to a question the platform has
        # already decided, and leaving the task untouched is what guarantees
        # that an unfinished report draft, a pending confirmation or a suspended
        # task survives the answer exactly as it was. That contract is right and
        # this module does not weaken it — an entity-free follow-up ("A kad se
        # završava trka?") still had nothing to attach itself to, and was
        # re-classified from scratch into the rewards catalogue.
        #
        # So the last ANSWER gets its own bounded record, and the task keeps
        # its own. Nothing here is an action, a permission or a slot: it is the
        # subject the previous reply was about, the citizen's own words for it,
        # and when it stops being usable.
        #
        # == Lifetime, and every way it ends
        #
        #   * replacement — every answered turn writes its own context, so the
        #     record always describes the LAST answer and never accumulates;
        #   * topic switch — a real task switch clears it (ProcedureRunner's
        #     +reset_task+), so a continuation can never reach across one;
        #   * cancellation and "novi razgovor" — +cancel+ rebuilds the state
        #     from +empty_state+ and the whole Redis value is deleted by a
        #     clear, so nothing survives either;
        #   * expiry — +TTL+ after it was opened, and never later than the
        #     conversation state itself;
        #   * write conflict — the writer is best-effort (see the coordinator):
        #     a refused CAS loses the context and keeps the ANSWER. Continuity
        #     is a convenience; an answer the citizen already read is not.
        #
        # Anything malformed is DROPPED rather than raised, exactly as the
        # reserved safety context is: a continuity hint must never be able to
        # destroy the conversation state around it.
        #
        # == What may never be retained here
        #
        # Private account facts. The anchor is the citizen's own QUESTION, never
        # a rendered answer, and a read about this citizen's own account, report
        # or neighbourhood membership is not captured at all — those are re-read
        # through the authorized port on every turn, which is the only place
        # that knows whether the reader may still see them. A credential-shaped
        # anchor is refused outright.
        module AnswerContext
          KEY = "answer_context_v1"
          FIELDS = %w(kind subject action topic facet anchor opened_at expires_at).freeze
          # A reviewed CARD, one kind per registry. Two kinds and not one
          # because a report-guidance card's name must never be resolved
          # against PublicInformation's constants, nor the other way round:
          # the kind is what says which registry owns the subject.
          CARD_KINDS = %w(public_card report_card).freeze
          KINDS = (CARD_KINDS + %w(core_read legacy_read)).freeze
          # The same window the reserved safety context uses. There is no turn
          # counter because there is nothing for one to bound: every answered
          # turn REPLACES the record, and an unanswered turn cannot extend it.
          TTL = 10 * 60
          SUBJECT = /\A[a-z][a-z0-9_:.-]{0,63}\z/
          # QuestionFacet's closed token list, repeated here so the state shape
          # stays independent of the router - the same discipline the state
          # store applies to the presentation level. An unknown token is
          # dropped, never raised.
          FACETS = %w(contact website operator hours fee coverage status location schedule).freeze
          ANCHOR_LIMIT = 160
          # Reads whose answer is about THIS citizen. Never retained: the next
          # turn must ask the authorized port again, not a ten-minute memory.
          PRIVATE_TOPICS = %w(account report neighborhood).freeze
          PRIVATE_ACTIONS = %w(
            report_problem registration sign_in link_account verification choose_area change_area
            preferences report_status neighborhood_post neighborhood_information help safety cancel
          ).freeze

          module_function

          # A validated record, or nil when this answer may not be retained.
          # Never raises: a caller that cannot retain simply does not.
          # rubocop:disable Metrics/ParameterLists
          def capture(kind:, subject:, anchor:, now:, state_expires_at:, action: nil, topic: nil, facet: nil)
            opened = now.to_f
            value = {
              "kind" => kind, "subject" => subject, "action" => action, "topic" => topic,
              "facet" => facet, "anchor" => bounded_anchor(anchor),
              "opened_at" => opened, "expires_at" => [opened + TTL, state_expires_at.to_f].min
            }
            normalize(value, now:, state_expires_at:)
          end
          # rubocop:enable Metrics/ParameterLists

          # Every rule below is a drop, never a raise. See the class comment.
          def normalize(value, now:, state_expires_at:)
            return nil unless value.is_a?(Hash)

            fields = value.transform_keys(&:to_s)
            return nil unless valid_shape?(fields)

            anchor = bounded_anchor(fields["anchor"])
            return nil if anchor.nil?

            valid_window?(fields, now:, state_expires_at:) ? Contracts.snapshot(fields.merge("anchor" => anchor)) : nil
          rescue ArgumentError, TypeError, KeyError, Contracts::Invalid
            nil
          end

          def valid_shape?(fields)
            fields.keys.sort == FIELDS.sort && KINDS.include?(fields["kind"]) &&
              fields["subject"].is_a?(String) && fields["subject"].match?(SUBJECT) &&
              valid_read_identity?(fields) && valid_facet?(fields["facet"])
          end

          # A card carries no action/topic; a read carries both, and neither may
          # be one of the private families above.
          #
          # The card rule is a REFUSAL, not a default: a card is answered from
          # reviewed copy and has no read identity to carry, so a caller that
          # supplies one is describing something this record cannot hold and
          # the whole capture is dropped. That is also what keeps the private
          # families below un-bypassable — a card kind can never smuggle
          # "report_problem"/"report" past them by carrying it.
          def valid_read_identity?(fields)
            action = fields["action"]
            topic = fields["topic"]
            return action.nil? && topic.nil? if CARD_KINDS.include?(fields["kind"])
            return false unless Contracts::ACTIONS.include?(action) && Contracts::TOPICS.include?(topic)

            !(PRIVATE_ACTIONS.include?(action) || PRIVATE_TOPICS.include?(topic) || topic == "unknown")
          end

          def valid_facet?(facet)
            facet.nil? || FACETS.include?(facet)
          end

          # The citizen's own words for the subject, bounded and never a
          # credential. Returns nil when there is nothing usable to retain.
          def bounded_anchor(value)
            return nil unless value.is_a?(String)

            text = value.strip
            return nil if text.empty? || text.length > ANCHOR_LIMIT
            return nil unless text.valid_encoding? && text.match?(/\p{L}/)
            return nil if text.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/)
            return nil if TextPredicates.credential?(text)

            text
          end

          def valid_window?(fields, now:, state_expires_at:)
            opened = Float(fields.fetch("opened_at"))
            expires = Float(fields.fetch("expires_at"))
            state_expiry = Float(state_expires_at)
            [opened, expires, state_expiry].all?(&:finite?) && opened.positive? && opened <= now.to_f &&
              now.to_f < expires && expires <= opened + TTL && expires <= state_expiry
          rescue ArgumentError, TypeError
            false
          end
        end
      end
    end
  end
end

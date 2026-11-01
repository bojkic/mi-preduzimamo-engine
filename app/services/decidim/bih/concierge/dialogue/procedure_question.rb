# frozen_string_literal: true

require_relative "../../text"
require_relative "prior_evidence"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Only an elliptical follow-up to the currently rendered public
        # procedure. Named new purchases/tasks continue through understanding.
        module ProcedureQuestion
          PROCEDURE_ID = /\Aprocedure:[a-z][a-z0-9_]{0,79}\z/
          LOCAL_FEE = /\A(?:a[ ])?(?:
            (?:gdje|gde)[ ](?:provjeravam|proveravam|(?:mogu[ ])?(?:provjeriti|proveriti))[ ](?:tu[ ])?(?:cijenu|cenu|taksu|postarinu)|
            koliko[ ](?:to[ ])?(?:kosta|kostaju)|kolik[ao][ ]je[ ](?:cijena|cena|taksa|postarina)|
            (?:sta|sto)[ ]je[ ]sa[ ]postarinom|postarina
          )\z/x
          ENGLISH_FEE = /\A(?:and )?(?:where (?:can i )?check (?:the )?(?:price|fee|postage)|how much (?:is it|does (?:it|that) cost)|what (?:is|about) (?:the )?(?:fee|postage))\z/

          module_function

          def fee_follow_up?(text)
            return false unless text.is_a?(String) && text.length <= 160

            folded = Text.fold(text)
            LOCAL_FEE.match?(folded) || ENGLISH_FEE.match?(folded)
          end

          def retained_id(state:, context:)
            evidence = procedure_evidence(state:, context:)
            return unless evidence && evidence.fetch("facts").one?

            fact = evidence.fetch("facts").first
            id = fact.fetch("id")
            id if PROCEDURE_ID.match?(id) && fact["source_id"] == id
          end

          def procedure_evidence(state:, context:)
            return unless context.is_a?(Contracts::TrustedContext) && context.allows?("public_reads")
            return unless state.is_a?(Hash) && state.values_at("active_task", "topic") == %w(ask_information city_service) && state["draft"].nil?

            evidence = PriorEvidence.normalize(state["prior_evidence"], now: context.now, state_expires_at: state.fetch("expires_at"))
            evidence if evidence && evidence.values_at("kind", "action", "topic") == %w(public_read ask_information city_service)
          rescue Contracts::Invalid, KeyError
            nil
          end

          private_class_method :procedure_evidence
        end
      end
    end
  end
end

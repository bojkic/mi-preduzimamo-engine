# frozen_string_literal: true

require_relative "../../text"
require_relative "prior_evidence"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Elliptical follow-ups may reuse one public directory identifier, not
        # previous prose, model entities, personal contacts or a retained URL.
        module ServiceFollowUpQuestion
          TOPICS = %w(waste water electricity transport parking heating roads city_service).freeze
          SOURCE_ID = /\Acity_services:([a-z][a-z0-9_]{0,79})\z/
          LOCAL_CONTACT = /\A(?:a[ ])?(?:
            (?:koji[ ]je[ ])?(?:(?:njihov|sluzbeni|kontakt)[ ])?(?:broj[ ]telefona|telefonski[ ]broj|telefon|kontakt)(?:[ ]sluzbe)?|
            kako[ ](?:da[ ]ih[ ]kontaktiram|ih[ ]mogu[ ]kontaktirati)
          )\z/x
          LOCAL_WEBSITE = /\A(?:a[ ])?(?:
            (?:(?:gdje|gde|koja)[ ]je[ ])?(?:njihova[ ])?(?:(?:sluzbena|zvanicna|web)[ ])?(?:stranica|sajt)|
            (?:gdje|gde)[ ](?:mogu[ ])?naci[ ]njihovu[ ](?:(?:sluzbenu|zvanicnu|web)[ ])?stranicu
          )\z/x
          ENGLISH_CONTACT = /\A(?:and[ ])?(?:
            (?:(?:what[ ]is|what[ ]s)[ ])?(?:(?:their|the[ ]service)[ ])?(?:phone[ ]number|telephone[ ]number|contact[ ]number|contact)|
            how[ ](?:can|do)[ ]i[ ]contact[ ]them
          )\z/x
          ENGLISH_WEBSITE = /\A(?:and[ ])?(?:
            (?:(?:where[ ]is|what[ ]is|what[ ]s)[ ])?(?:their[ ])?(?:official[ ])?(?:website|site)|
            where[ ]can[ ]i[ ]find[ ]their[ ](?:official[ ])?website
          )\z/x

          module_function

          def focus(text)
            return unless text.is_a?(String) && text.length <= 160

            folded = Text.fold(text)
            return "contact" if LOCAL_CONTACT.match?(folded) || ENGLISH_CONTACT.match?(folded)
            return "website" if LOCAL_WEBSITE.match?(folded) || ENGLISH_WEBSITE.match?(folded)
          end

          def retained_source_id(state:, context:)
            evidence = directory_evidence(state:, context:)
            return unless evidence && evidence.fetch("facts").one?

            fact = evidence.fetch("facts").first
            source = fact.fetch("source_id")
            match = SOURCE_ID.match(source)
            source if match && fact.fetch("id") == "service:#{match[1]}"
          end

          def directory_evidence(state:, context:)
            return unless context.is_a?(Contracts::TrustedContext) && context.allows?("public_reads")
            return unless state.is_a?(Hash) && state["active_task"] == "ask_information" && TOPICS.include?(state["topic"]) && state["draft"].nil?

            evidence = PriorEvidence.normalize(state["prior_evidence"], now: context.now, state_expires_at: state.fetch("expires_at"))
            evidence if evidence && evidence.values_at("kind", "action", "topic") == ["public_read", "ask_information", state["topic"]]
          rescue Contracts::Invalid, KeyError
            nil
          end
          private_class_method :directory_evidence
        end
      end
    end
  end
end
